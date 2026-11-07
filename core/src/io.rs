//! Line-based JSON messages between the helper and the Mac app.

use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use std::io::{BufRead, Write};
use std::sync::Mutex;

static STDIN_LOCK: Mutex<()> = Mutex::new(());

pub fn emit(value: Value) {
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{value}");
    let _ = stdout.flush();
}

pub fn log(message: impl Into<String>) {
    emit(json!({ "event": "log", "message": message.into() }));
}

/// Reads one JSON object from stdin.
pub fn read_reply() -> Result<Value> {
    let _guard = STDIN_LOCK.lock().map_err(|_| anyhow!("stdin lock poisoned"))?;
    let mut line = String::new();
    let read = std::io::stdin().lock().read_line(&mut line)?;
    if read == 0 {
        return Err(anyhow!("Cancelled"));
    }
    serde_json::from_str(line.trim()).context("Invalid reply")
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
