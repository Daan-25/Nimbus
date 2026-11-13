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
    /// Where to keep the signing key and anisette state, instead of the Keychain.
    pub storage_dir: Option<PathBuf>,
    /// The folder with the developer disk image, where that isn't Xcode's.
    pub ddi_dir: Option<PathBuf>,
}

/// A device reached by address with a remote pairing file, without usbmuxd.
/// On iOS the address is that of the device itself as seen through the loopback VPN.
#[derive(Clone, Deserialize)]
pub struct LocalDevice {
    pub address: IpAddr,
    /// Port of the device's pairing service; 49152 when left out.
    pub port: Option<u16>,
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
