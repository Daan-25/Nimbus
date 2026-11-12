//! C interface for apps that link the engine instead of running nimbus-helper.
//!
//! One command runs at a time. Events arrive through the callback as JSON text, on the thread
//! that called `nimbus_run` or on a worker thread. See include/nimbus_core.h.

use crate::{config, io};
use anyhow::{Result, anyhow};
use serde::Deserialize;
use serde_json::Value;
use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex, OnceLock};
use tokio::sync::Notify;

pub type NimbusCallback = extern "C" fn(context: *mut c_void, json: *const c_char);

#[derive(Deserialize)]
struct RunRequest {
    command: String,
    #[serde(default)]
    args: Vec<String>,
    /// For "install": the install request, which nimbus-helper reads from stdin.
    request: Option<Value>,
}

struct CallbackTransport {
    callback: NimbusCallback,
    context: *mut c_void,
    /// None means the app cancelled.
    replies: Mutex<Receiver<Option<Value>>>,
}

// The app promises its callback and context can be used from any thread.
unsafe impl Send for CallbackTransport {}
unsafe impl Sync for CallbackTransport {}

impl io::Transport for CallbackTransport {
    fn emit(&self, value: Value) {
        if let Ok(text) = CString::new(value.to_string()) {
            (self.callback)(self.context, text.as_ptr());
        }
    }

    fn read_reply(&self) -> Result<Value> {
        let replies = self.replies.lock().map_err(|_| anyhow!("Cancelled"))?;
        replies
            .recv()
            .ok()
            .flatten()
            .ok_or_else(|| anyhow!("Cancelled"))
    }
}

/// The running command's reply channel and cancel signal.
struct Running {
    replies: Sender<Option<Value>>,
    cancel: Arc<Notify>,
}

/// The engine's futures are large, and the threads an app calls from have small stacks
/// (512 KB on iOS), which overflowed while opening the tunnel. So commands get their own.
const STACK_SIZE: usize = 16 * 1024 * 1024;

static RUN_LOCK: Mutex<()> = Mutex::new(());
static RUNNING: Mutex<Option<Running>> = Mutex::new(None);

fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .thread_stack_size(STACK_SIZE)
            .enable_all()
            .build()
            .expect("Failed to start the tokio runtime")
    })
}

fn parse<T: for<'de> Deserialize<'de>>(json: *const c_char) -> Option<T> {
    if json.is_null() {
        return None;
    }
    let text = unsafe { CStr::from_ptr(json) }.to_str().ok()?;
    serde_json::from_str(text).ok()
}

/// Sets the device to connect to and the identity to report to Apple. See `config::Config`.
#[unsafe(no_mangle)]
pub extern "C" fn nimbus_configure(json: *const c_char) -> bool {
    match parse::<config::Config>(json) {
        Some(config) => {
            config::set(config);
            true
        }
        None => false,
    }
}

/// Runs a command, {"command": "apps", "args": ["UDID"], "request": {...}}, and returns once
/// it's finished. Returns whether it succeeded; a failure also arrives as an "error" event.
#[unsafe(no_mangle)]
pub extern "C" fn nimbus_run(
    json: *const c_char,
    callback: NimbusCallback,
    context: *mut c_void,
) -> bool {
    let Some(request) = parse::<RunRequest>(json) else {
        return false;
    };
    let Ok(_one_at_a_time) = RUN_LOCK.lock() else {
        return false;
    };

    let (replies, receiver) = channel();
    if let Some(install) = request.request {
        let _ = replies.send(Some(install));
    }
    let cancel = Arc::new(Notify::new());
    if let Ok(mut running) = RUNNING.lock() {
        *running = Some(Running {
            replies,
            cancel: cancel.clone(),
        });
    }
    io::set_transport(Arc::new(CallbackTransport {
        callback,
        context,
        replies: Mutex::new(receiver),
    }));

    let command = std::thread::Builder::new()
        .name("nimbus-engine".to_string())
        .stack_size(STACK_SIZE)
        .spawn(move || {
            runtime().block_on(async {
                tokio::select! {
                    succeeded = crate::run(&request.command, &request.args) => succeeded,
                    // Dropping the command stops it, like quitting nimbus-helper does.
                    _ = cancel.notified() => false,
                }
            })
        });
    // A panic in the engine ends the command instead of the app.
    let succeeded = command
        .ok()
        .and_then(|thread| thread.join().ok())
        .unwrap_or(false);

    if let Ok(mut running) = RUNNING.lock() {
        *running = None;
    }
    succeeded
}

/// Answers the prompt the running command is waiting on.
#[unsafe(no_mangle)]
pub extern "C" fn nimbus_reply(json: *const c_char) {
    let Some(reply) = parse::<Value>(json) else {
        return;
    };
    if let Ok(running) = RUNNING.lock()
        && let Some(running) = running.as_ref()
    {
        let _ = running.replies.send(Some(reply));
    }
}

/// Stops the running command. `nimbus_run` then returns false without an "error" event.
#[unsafe(no_mangle)]
pub extern "C" fn nimbus_cancel() {
    if let Ok(running) = RUNNING.lock()
        && let Some(running) = running.as_ref()
    {
        let _ = running.replies.send(None);
        running.cancel.notify_one();
    }
}
