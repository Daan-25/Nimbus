//! JSON messages between the engine and the app: events out, replies to prompts in.

use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use std::io::{BufRead, Write};
use std::sync::{Arc, Mutex, RwLock};

/// How messages travel: over stdio for nimbus-helper, through callbacks inside an app.
pub trait Transport: Send + Sync {
    fn emit(&self, value: Value);
    /// Waits for one reply. An error means the app cancelled.
    fn read_reply(&self) -> Result<Value>;
}

static TRANSPORT: RwLock<Option<Arc<dyn Transport>>> = RwLock::new(None);

pub fn set_transport(transport: Arc<dyn Transport>) {
    if let Ok(mut current) = TRANSPORT.write() {
        *current = Some(transport);
    }
}

fn transport() -> Option<Arc<dyn Transport>> {
    TRANSPORT
        .read()
        .ok()
        .and_then(|transport| transport.clone())
}

pub fn emit(value: Value) {
    if let Some(transport) = transport() {
        transport.emit(value);
    }
}

pub fn log(message: impl Into<String>) {
    emit(json!({ "event": "log", "message": message.into() }));
}

pub fn read_reply() -> Result<Value> {
    transport()
        .ok_or_else(|| anyhow!("Cancelled"))?
        .read_reply()
}

/// One JSON object per line: events on stdout, replies on stdin.
pub struct Stdio;

static STDIN_LOCK: Mutex<()> = Mutex::new(());

impl Transport for Stdio {
    fn emit(&self, value: Value) {
        let mut stdout = std::io::stdout().lock();
        let _ = writeln!(stdout, "{value}");
        let _ = stdout.flush();
    }

    fn read_reply(&self) -> Result<Value> {
        let _guard = STDIN_LOCK
            .lock()
            .map_err(|_| anyhow!("stdin lock poisoned"))?;
        let mut line = String::new();
        let read = std::io::stdin().lock().read_line(&mut line)?;
        if read == 0 {
            return Err(anyhow!("Cancelled"));
        }
        serde_json::from_str(line.trim()).context("Invalid reply")
    }
}

/// Sends a prompt event and waits for the reply.
pub fn ask(event: Value) -> Result<Value> {
    emit(event);
    read_reply()
}

/// Logs go to stderr so stdout stays machine-readable. Set RUST_LOG for more detail.
pub fn init_logging() {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_ansi(false)
        .try_init();
}
