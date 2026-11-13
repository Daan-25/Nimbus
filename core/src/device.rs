//! Finding the device and connecting to it.
//!
//! On a Mac, Nimbus reaches a device through usbmuxd, over a cable or Wi-Fi. On the device
//! itself there is no usbmuxd: Nimbus connects to the device's own address through a loopback
//! VPN, proves who it is with a remote pairing file, and opens an encrypted tunnel. Since
//! iOS 26.4, devices hang up on the older lockdown connection when it comes from themselves.

use crate::config::{self, LocalDevice};
use crate::io;
use anyhow::{Result, anyhow};
use idevice::{
    IdeviceError, IdeviceService, RsdService,
    core_device_proxy::CoreDeviceProxy,
    installation_proxy::InstallationProxyClient,
    lockdown::LockdownClient,
    provider::UsbmuxdProvider,
    remote_pairing::{
        RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
    },
    rsd::RsdHandshake,
    tcp::{adapter::Adapter, handle::AdapterHandle},
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice},
};
use isideload::util::device::IdeviceInfo;
use rootcause::Report;
use serde_json::{Value, json};
use std::net::{IpAddr, SocketAddr};
use std::path::Path;
use std::time::Duration;
use tokio::net::TcpStream;

const LABEL: &str = "nimbus";
/// The name Nimbus pairs under. A device keeps one remote pairing per name.
pub const HOST_NAME: &str = "Nimbus";
/// Where a device's pairing service normally listens: the first port iOS hands out.
pub const DEFAULT_PAIRING_PORT: u16 = 49152;
/// Without the VPN, a connection to the device's own address can hang instead of failing.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);

/// A connection to a device.
pub enum Link {
    Usb(UsbmuxdProvider),
    Tunnel(Box<Tunnel>),
}

/// An encrypted tunnel to a device, with the list of services reachable through it.
pub struct Tunnel {
    pub(crate) adapter: AdapterHandle,
    pub(crate) services: RsdHandshake,
}

impl Link {
    pub async fn info(&mut self) -> Result<IdeviceInfo> {
        match self {
            Link::Usb(provider) => IdeviceInfo::from_device(provider)
                .await
                .map_err(|e| anyhow!("Can't read your device: {e}")),
            Link::Tunnel(tunnel) => {
                let mut lockdown =
                    LockdownClient::connect_rsd(&mut tunnel.adapter, &mut tunnel.services)
                        .await
                        .map_err(|e| anyhow!("Can't read this device: {e}"))?;
                let mut text = async |key: &str| {
                    lockdown
                        .get_value(Some(key), None)
                        .await
                        .ok()
                        .and_then(|v| v.as_string().map(str::to_string))
                };
                let name = text("DeviceName")
                    .await
                    .unwrap_or_else(|| "This device".to_string());
                let udid = text("UniqueDeviceID")
                    .await
                    .ok_or_else(|| anyhow!("Can't read this device's identifier."))?;
                Ok(IdeviceInfo::new(name, udid))
            }
        }
    }

    pub async fn installation_proxy(&mut self) -> Result<InstallationProxyClient, IdeviceError> {
        match self {
            Link::Usb(provider) => InstallationProxyClient::connect(provider).await,
            Link::Tunnel(tunnel) => {
                InstallationProxyClient::connect_rsd(&mut tunnel.adapter, &mut tunnel.services)
                    .await
            }
        }
    }

    /// Installs an app that's already signed. Progress runs from 0 to 100.
    pub async fn install(
        &mut self,
        app: &Path,
        progress: impl Fn(u64) + Send + Sync,
    ) -> Result<(), Report> {
        use isideload::sideload::install::{install_app, install_app_rsd};
        match self {
            Link::Usb(provider) => install_app(provider, app, progress).await,
            Link::Tunnel(tunnel) => {
                install_app_rsd(&mut tunnel.adapter, &mut tunnel.services, app, progress).await
            }
        }
    }
}

pub fn is_local() -> bool {
    config::get().local_device.is_some()
}

/// Opens the tunnel to a device reached by address. `step` hears about each stage that
/// worked, so a failure shows how far the connection got.
async fn open_tunnel(device: &LocalDevice, step: &(dyn Fn(String) + Sync)) -> Result<Tunnel> {
    let mut pairing = RpPairingFile::read_from_file(&device.pairing_file)
        .await
        .map_err(|e| {
            anyhow!("Can't read the pairing file. Set Nimbus up again from your Mac. ({e:?})")
        })?;
    step("Pairing file: readable".to_string());

    let address = SocketAddr::new(device.address, device.port.unwrap_or(DEFAULT_PAIRING_PORT));
    let stream = connect(address, "the pairing service").await?;
    step(format!("Pairing service at {address}: connected"));

    let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), HOST_NAME);
    client
        .attempt_pair_verify()
        .await
        .map_err(|e| anyhow!("The pairing service didn't answer: {e} ({e:?})"))?;
    // Only check the pairing. Pairing anew needs the Mac, so don't start that here.
    client.validate_pairing(&mut pairing).await.map_err(|e| {
        anyhow!("This device doesn't accept the pairing file. Set Nimbus up again from your Mac. ({e:?})")
    })?;
    step("Pairing: accepted".to_string());

    let port = client
        .create_tcp_listener()
        .await
        .map_err(|e| anyhow!("The device didn't open a tunnel: {e} ({e:?})"))?;
    step(format!("Tunnel port: {port}"));
    let stream = connect(SocketAddr::new(device.address, port), "the tunnel").await?;
    let tunnel = connect_tls_psk_tunnel_native(stream, client.encryption_key())
        .await
        .map_err(|e| anyhow!("Couldn't set up the tunnel: {e} ({e:?})"))?;
    step("Tunnel: open".to_string());

    let client_address: IpAddr = tunnel.info.client_address.parse()?;
    let server_address: IpAddr = tunnel.info.server_address.parse()?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;

    // The tunnel carries raw network packets, so Nimbus runs its own small TCP stack on top.
    let mut adapter = Adapter::new(
        Box::new(tunnel.into_inner()),
        client_address,
        server_address,
    );
    adapter.set_mss(mtu.min(8192) - 60);
    let mut adapter = adapter.to_async_handle();

    let stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|e| anyhow!("Couldn't reach the device through the tunnel: {e}"))?;
    let services = RsdHandshake::new(stream)
        .await
        .map_err(|e| anyhow!("The device didn't list its services: {e} ({e:?})"))?;
    step(format!("Services: {}", services.services.len()));

    Ok(Tunnel { adapter, services })
}

async fn connect(address: SocketAddr, what: &str) -> Result<TcpStream> {
    match tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(address)).await {
        Ok(Ok(stream)) => Ok(stream),
        Ok(Err(error)) => Err(anyhow!(
            "Can't connect to {what} at {address}: {error} ({:?})",
            error.kind()
        )),
        Err(_) => Err(anyhow!("Can't connect to {what} at {address}: no answer")),
    }
}

/// Walks through connecting to the local device one step at a time and reports each result,
/// to find out why Nimbus on the device can't reach it.
pub async fn diagnose() -> Result<()> {
    let Some(device) = config::get().local_device else {
        return Err(anyhow!("This only works in Nimbus on your iPhone or iPad."));
    };
    io::log(format!(
        "Address: {}, port {}",
        device.address,
        device.port.unwrap_or(DEFAULT_PAIRING_PORT)
    ));

    match open_tunnel(&device, &|step| io::log(step)).await {
        Ok(tunnel) => {
            let mut link = Link::Tunnel(Box::new(tunnel));
            match link.info().await {
                Ok(info) => io::log(format!("Device: {}", info.name)),
                Err(error) => io::log(format!("Device: {error}")),
            }
            match link.installation_proxy().await {
                Ok(_) => io::log("Apps service: reachable".to_string()),
                Err(error) => io::log(format!("Apps service: {error} ({error:?})")),
            }
            if let Link::Tunnel(tunnel) = &link {
                io::log(format!(
                    "Debugger (for JIT): {}",
                    if crate::ddi::is_mounted(tunnel) {
                        "available"
                    } else {
                        "not available; the developer disk image isn't mounted"
                    }
                ));
            }
        }
        Err(error) => io::log(format!("Failed: {error}")),
    }
    io::emit(json!({ "event": "done" }));
    Ok(())
}

async fn usb_devices() -> Result<Vec<UsbmuxdDevice>> {
    let mut usbmuxd = UsbmuxdConnection::default()
        .await
        .map_err(|e| anyhow!("Can't reach usbmuxd: {e}"))?;
    let mut devices = usbmuxd
        .get_devices()
        .await
        .map_err(|e| anyhow!("Can't list devices via usbmuxd: {e}"))?;
    // A device connected over both USB and Wi-Fi shows up twice; prefer USB, which is faster.
    devices.sort_by_key(|d| !matches!(d.connection_type, Connection::Usb));
    let mut seen = std::collections::HashSet::new();
    devices.retain(|d| seen.insert(d.udid.clone()));
    Ok(devices)
}

/// The devices Nimbus can install on, as {"udid", "name", "connection"}.
pub async fn list() -> Result<Vec<Value>> {
    if let Some(device) = config::get().local_device {
        // Not reachable usually means the VPN is off; that's a state to show, not an error.
        let info = async {
            let tunnel = open_tunnel(&device, &|_| {}).await?;
            Link::Tunnel(Box::new(tunnel)).info().await
        };
        return Ok(match info.await {
            Ok(info) => {
                vec![json!({ "udid": info.udid, "name": info.name, "connection": "local" })]
            }
            Err(error) => {
                io::log(format!("{error}"));
                vec![]
            }
        });
    }

    let mut list = Vec::new();
    for device in usb_devices().await? {
        let connection = match device.connection_type {
            Connection::Usb => "usb",
            Connection::Network(_) => "wifi",
            Connection::Unknown(_) => "unknown",
        };
        let provider = device.to_provider(UsbmuxdAddr::from_env_var()?, LABEL);
        let name = IdeviceInfo::from_device(&provider)
            .await
            .map(|info| info.name)
            .unwrap_or_else(|_| "Unnamed device".to_string());
        list.push(json!({ "udid": device.udid, "name": name, "connection": connection }));
    }
    Ok(list)
}

/// The device with this UDID as usbmuxd on this Mac sees it.
#[cfg(target_os = "macos")]
pub async fn usb_provider(udid: &str) -> Result<UsbmuxdProvider> {
    let device = usb_devices()
        .await?
        .into_iter()
        .find(|d| d.udid == udid)
        .ok_or_else(|| {
            anyhow!("No device found. Connect your iPhone or iPad with a cable and unlock it.")
        })?;
    Ok(device.to_provider(UsbmuxdAddr::from_env_var()?, LABEL))
}

/// Opens a tunnel to a device, which the debugger and the app service need. On the device
/// itself that's the remote pairing tunnel; on a Mac it runs over the usbmuxd connection.
pub async fn tunnel_for(udid: Option<&str>) -> Result<Tunnel> {
    if let Some(device) = config::get().local_device {
        return open_tunnel(&device, &|_| {}).await;
    }

    let device = usb_devices()
        .await?
        .into_iter()
        .find(|d| udid.is_none_or(|udid| d.udid == udid))
        .ok_or_else(|| {
            anyhow!("No device found. Connect your iPhone or iPad with a cable and unlock it.")
        })?;
    let provider = device.to_provider(UsbmuxdAddr::from_env_var()?, LABEL);
    let proxy = CoreDeviceProxy::connect(&provider)
        .await
        .map_err(|e| anyhow!("Can't open a tunnel to your device: {e}"))?;
    let rsd_port = proxy.tunnel_info().server_rsd_port;
    let mut adapter = proxy
        .create_software_tunnel()
        .map_err(|e| anyhow!("Can't open a tunnel to your device: {e}"))?
        .to_async_handle();
    let stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|e| anyhow!("Couldn't reach the device through the tunnel: {e}"))?;
    let services = RsdHandshake::new(stream)
        .await
        .map_err(|e| anyhow!("The device didn't list its services: {e} ({e:?})"))?;
    Ok(Tunnel { adapter, services })
}

pub async fn link_for(udid: Option<&str>) -> Result<Link> {
    if let Some(device) = config::get().local_device {
        let tunnel = open_tunnel(&device, &|_| {}).await?;
        return Ok(Link::Tunnel(Box::new(tunnel)));
    }

    let device = usb_devices()
        .await?
        .into_iter()
        .find(|d| udid.is_none_or(|udid| d.udid == udid))
        .ok_or_else(|| {
            anyhow!("No device found. Connect your iPhone or iPad with a cable and unlock it.")
        })?;
    Ok(Link::Usb(
        device.to_provider(UsbmuxdAddr::from_env_var()?, LABEL),
    ))
}
