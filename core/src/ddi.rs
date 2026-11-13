//! The developer disk image: the part of iOS that holds the debugger. It isn't on a device
//! until something mounts it, and it's gone again after a restart.
//!
//! Since iOS 26.4 the image is a "cryptex" that the device only accepts with a ticket Apple
//! signs for that one device. Nimbus mounts that kind. Xcode ships the image; on a device,
//! Nimbus uses the copy its Mac sent along.

use crate::device::Tunnel;
use crate::{config, io};
use anyhow::{Result, anyhow, bail};
use idevice::cryptexd::{self, Cryptex1Assets};
use std::path::PathBuf;

/// The debugger's service only shows up once the image is mounted.
const DEBUG_SERVICE: &str = "com.apple.internal.dt.remote.debugproxy";
const CRYPTEX_SERVICE: &str = "com.apple.security.cryptexd.remote";
/// Where Xcode keeps the image on a Mac.
const XCODE_IMAGE: &str = "/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore";

pub fn is_mounted(tunnel: &Tunnel) -> bool {
    tunnel.services.services.contains_key(DEBUG_SERVICE)
}

/// The folder with the image: the one the app passed in, or else Xcode's.
pub fn image_folder() -> Option<PathBuf> {
    let folder = config::get()
        .ddi_dir
        .unwrap_or_else(|| PathBuf::from(XCODE_IMAGE));
    folder
        .join("BuildManifest.plist")
        .is_file()
        .then_some(folder)
}

/// Mounts the image. The list of services in `tunnel` is from before the mount, so open a new
/// tunnel to use the debugger.
pub async fn mount(tunnel: &mut Tunnel) -> Result<()> {
    if !tunnel.services.services.contains_key(CRYPTEX_SERVICE) {
        bail!(
            "Nimbus can only mount the developer disk image on iOS 26.4 and later. On older \
             versions, connect the device to a Mac with Xcode open; that mounts it."
        );
    }
    let folder = image_folder().ok_or_else(|| {
        anyhow!(
            "Nimbus has no developer disk image to mount. It comes with Xcode: install Xcode on \
             your Mac, then let Nimbus on the Mac copy your apps to this device again."
        )
    })?;
    let assets = Cryptex1Assets::load(&folder)
        .await
        .map_err(|e| anyhow!("The developer disk image is incomplete: {e}"))?;

    io::log("Mounting the developer disk image. Apple signs it for this device first…");
    cryptexd::install_ddi(&mut tunnel.adapter, &mut tunnel.services, &assets)
        .await
        .map_err(|e| anyhow!("Couldn't mount the developer disk image: {e} ({e:?})"))?;
    io::log("The developer disk image is mounted.");
    Ok(())
}

/// Unmounts the image, which is what a restart does. For trying the mount again.
pub async fn unmount(tunnel: &mut Tunnel) -> Result<()> {
    let Some(installed) = cryptexd::installed_ddi(&mut tunnel.adapter, &mut tunnel.services)
        .await
        .map_err(|e| anyhow!("Can't read what's mounted: {e}"))?
    else {
        io::log("The developer disk image isn't mounted.");
        return Ok(());
    };
    use idevice::RsdService as _;
    let client: cryptexd::CryptexdClient<Box<dyn idevice::ReadWrite>> =
        cryptexd::CryptexdClient::connect_rsd(&mut tunnel.adapter, &mut tunnel.services)
            .await
            .map_err(|e| anyhow!("Can't reach the device: {e}"))?;
    client
        .uninstall(&installed.identifier, Some(&installed.version))
        .await
        .map_err(|e| anyhow!("Couldn't unmount the developer disk image: {e} ({e:?})"))?;
    io::log("The developer disk image is unmounted.");
    Ok(())
}
