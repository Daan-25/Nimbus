//! nimbus-helper: the sideloading engine as a command-line tool, which the Mac app runs.
//!
//! Commands:
//!   nimbus-helper client-info   prints the identity Nimbus reports to Apple
//!   nimbus-helper devices       prints the connected devices
//!   nimbus-helper apps UDID     prints the sideloaded apps on a device
//!   nimbus-helper uninstall UDID BUNDLE_ID
//!   nimbus-helper install       reads an install request from stdin, then answers prompts
//!
//! Events go to stdout and replies come from stdin, one JSON object per line.

use std::sync::Arc;

#[tokio::main]
async fn main() {
    nimbus_core::io::set_transport(Arc::new(nimbus_core::io::Stdio));
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_default();
    let args: Vec<String> = args.collect();
    if !nimbus_core::run(&command, &args).await {
        std::process::exit(1);
    }
}
