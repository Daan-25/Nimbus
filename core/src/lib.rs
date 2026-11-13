//! The sideloading engine behind Nimbus: signs in to Apple, signs apps and installs them.
//!
//! The Mac app runs it as the nimbus-helper tool; the iOS app links it and calls [`ffi`].
//! Either way they exchange JSON objects:
//!
//! Events:  {"event": "log" | "progress" | "two_factor" | "signed_in" | "select_team" |
//!           "revoke_certs" | "installing" | "installed" | "app_failed" | "limits" |
//!           "done" | "error" | "devices" | "apps" | "uninstalled" | "client_info" |
//!           "phone_ready", ...}
//! Replies: {"code": "123456"} | {"action": "resend" | "devices" | "sms" | "abort", "number_id": 1}
//!          {"team_id": "..."} | {"serials": ["..."]}

mod client_info;
pub mod config;
mod ddi;
mod device;
mod engine;
pub mod ffi;
pub mod io;
mod jit;
mod profiles;
#[cfg(target_os = "macos")]
mod setup;
mod storage;

pub use engine::run;
