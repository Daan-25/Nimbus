//! Settings for running inside an app instead of as nimbus-helper on a Mac.

use serde::Deserialize;
use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::RwLock;

#[derive(Clone, Default, Deserialize)]
pub struct Config {
    /// Set on iOS, where the device is the one Nimbus runs on.
    pub local_device: Option<LocalDevice>,
    /// The identity to report to Apple. On iOS this is the Mac that set Nimbus up,
    /// so accounts with Advanced Data Protection keep working.
    pub client_info: Option<String>,
    pub user_agent: Option<String>,
}

/// A device reached over the network with a pairing file, without usbmuxd.
/// On iOS the address is that of the device itself as seen through the loopback VPN.
#[derive(Clone, Deserialize)]
pub struct LocalDevice {
    pub address: IpAddr,
    pub pairing_file: PathBuf,
}

static CONFIG: RwLock<Option<Config>> = RwLock::new(None);

pub fn set(config: Config) {
    if let Ok(mut current) = CONFIG.write() {
        *current = Some(config);
    }
}

pub fn get() -> Config {
    CONFIG
        .read()
        .ok()
        .and_then(|config| config.clone())
        .unwrap_or_default()
}
