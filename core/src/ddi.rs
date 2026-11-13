//! The developer disk image: the part of iOS that holds the debugger. It isn't on a device
//! until something mounts it, and it's gone again after a restart.

use crate::device::Tunnel;
use anyhow::{Result, bail};

/// The debugger's service only shows up once the image is mounted.
const DEBUG_SERVICE: &str = "com.apple.internal.dt.remote.debugproxy";

pub fn is_mounted(tunnel: &Tunnel) -> bool {
    tunnel.services.services.contains_key(DEBUG_SERVICE)
}

pub async fn ensure_mounted(tunnel: &mut Tunnel) -> Result<()> {
    if is_mounted(tunnel) {
        return Ok(());
    }
    bail!(
        "The developer disk image isn't mounted on this device, so there's no debugger to use. \
         Nimbus can't mount it yet. Xcode mounts it when the device is connected to a Mac with \
         Xcode open; it stays until the device restarts."
    )
}
