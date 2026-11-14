//! nimbus-helper: the sideloading engine as a command-line tool, which the Mac app runs.
//!
//! Commands:
//!   nimbus-helper client-info   prints the identity Nimbus reports to Apple
//!   nimbus-helper devices       prints the connected devices
//!   nimbus-helper apps UDID     prints the sideloaded apps on a device
//!   nimbus-helper uninstall UDID BUNDLE_ID
//!   nimbus-helper deactivate UDID BUNDLE_ID FOLDER   takes an app's profile off the device, keeping app and data
//!   nimbus-helper activate UDID BUNDLE_ID FOLDER     puts that profile back
//!   nimbus-helper wake UDID BUNDLE_ID FOLDER          opens an app, activating it first when needed
//!   nimbus-helper archive UDID BUNDLE_ID FOLDER      keeps an app's data in FOLDER and removes the app
//!   nimbus-helper unarchive UDID BUNDLE_ID FOLDER CACHE   puts the app and its data back, from the signed copy in CACHE
//!   nimbus-helper swap UDID BUNDLE_ID FOLDER CACHE [MAKE_ROOM]   archives MAKE_ROOM, restores BUNDLE_ID and opens it
//!   nimbus-helper backup UDID BUNDLE_ID FOLDER       copies an app's data off the device
//!   nimbus-helper restore UDID BUNDLE_ID FOLDER      copies it back into the app
//!   nimbus-helper install       reads an install request from stdin, then answers prompts
//!   nimbus-helper setup-phone UDID BUNDLE_ID [APPLE_ID]   gives Nimbus on the device its pairing file
//!   nimbus-helper phone-status UDID BUNDLE_ID  prints what Nimbus on the device refreshed itself
//!   nimbus-helper sync-phone UDID BUNDLE_ID    copies apps to Nimbus on the device; reads which from stdin
//!   nimbus-helper pairing-file UDID PATH       saves a remote pairing file on this Mac
//!   nimbus-helper crash-log UDID NAME          prints the device's newest crash report of an app
//!   nimbus-helper inspect PATH                 prints what an .ipa file contains
//!   nimbus-helper jit UDID BUNDLE_ID           starts an app with JIT enabled
//!   nimbus-helper ddi UDID [mount|unmount]     shows or changes whether the developer disk image is mounted
//!   nimbus-helper diagnose      tests the connection the iPhone app makes, step by step
//!
//! Events go to stdout and replies come from stdin, one JSON object per line.

use std::sync::Arc;

#[tokio::main]
async fn main() {
    // For trying the connection the iPhone app makes, from this Mac over Wi-Fi.
    if let (Ok(address), Ok(pairing_file)) = (
        std::env::var("NIMBUS_DEVICE_ADDRESS"),
        std::env::var("NIMBUS_PAIRING_FILE"),
    ) && let Ok(address) = address.parse()
    {
        nimbus_core::config::set(nimbus_core::config::Config {
            local_device: Some(nimbus_core::config::LocalDevice {
                address,
                port: std::env::var("NIMBUS_DEVICE_PORT")
                    .ok()
                    .and_then(|port| port.parse().ok()),
                pairing_file: pairing_file.into(),
            }),
            ..Default::default()
        });
    }
    nimbus_core::io::set_transport(Arc::new(nimbus_core::io::Stdio));
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_default();
    let args: Vec<String> = args.collect();
    if !nimbus_core::run(&command, &args).await {
        std::process::exit(1);
    }
}
