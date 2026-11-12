//! Finding the device and connecting to it.

use crate::config::{self, LocalDevice};
use anyhow::{Result, anyhow};
use idevice::{
    Idevice, IdeviceError, IdeviceService,
    heartbeat::HeartbeatClient,
    pairing_file::PairingFile,
    provider::{IdeviceProvider, TcpProvider, UsbmuxdProvider},
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice},
};
use isideload::util::device::IdeviceInfo;
use serde_json::{Value, json};
use std::future::Future;
use std::pin::Pin;

const LABEL: &str = "nimbus";

/// A connection to a device: through usbmuxd on a Mac, or straight over the network.
#[derive(Debug)]
pub enum Provider {
    Usb(UsbmuxdProvider),
    Local {
        provider: TcpProvider,
        /// Held so the connection stays alive for as long as the provider is used.
        _heartbeat: Option<Heartbeat>,
    },
}

impl IdeviceProvider for Provider {
    fn connect(
        &self,
        port: u16,
    ) -> Pin<Box<dyn Future<Output = Result<Idevice, IdeviceError>> + Send>> {
        match self {
            Provider::Usb(provider) => provider.connect(port),
            Provider::Local { provider, .. } => provider.connect(port),
        }
    }

    fn label(&self) -> &str {
        LABEL
    }

    fn get_pairing_file(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<PairingFile, IdeviceError>> + Send>> {
        match self {
            Provider::Usb(provider) => provider.get_pairing_file(),
            Provider::Local { provider, .. } => provider.get_pairing_file(),
        }
    }
}

/// Keeps a network connection to the device alive; stops when dropped.
#[derive(Debug)]
pub struct Heartbeat(tokio::task::JoinHandle<()>);

impl Drop for Heartbeat {
    fn drop(&mut self) {
        self.0.abort();
    }
}

impl Heartbeat {
    /// A device drops network connections when nothing answers its heartbeat.
    async fn start(provider: &TcpProvider) -> Option<Heartbeat> {
        let mut client = match HeartbeatClient::connect(provider).await {
            Ok(client) => client,
            Err(error) => {
                tracing::warn!("Couldn't start the heartbeat: {error}");
                return None;
            }
        };
        Some(Heartbeat(tokio::spawn(async move {
            let mut interval = 15;
            loop {
                match client.get_marco(interval).await {
                    Ok(next) => interval = next + 5,
                    Err(_) => break,
                }
                if client.send_polo().await.is_err() {
                    break;
                }
            }
        })))
    }
}

pub fn is_local() -> bool {
    config::get().local_device.is_some()
}

fn local_provider(device: &LocalDevice) -> Result<TcpProvider> {
    let pairing_file = PairingFile::read_from_file(&device.pairing_file).map_err(|e| {
        anyhow!("Can't read the pairing file. Set Nimbus up again from your Mac. ({e})")
    })?;
    Ok(TcpProvider {
        addr: device.address,
        scope_id: None,
        pairing_file,
        label: LABEL.to_string(),
    })
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
        let provider = local_provider(&device)?;
        // Not reachable means the VPN is off; that's a state to show, not an error.
        return Ok(match IdeviceInfo::from_device(&provider).await {
            Ok(info) => {
                vec![json!({ "udid": info.udid, "name": info.name, "connection": "local" })]
            }
            Err(_) => vec![],
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

pub async fn provider_for(udid: Option<&str>) -> Result<Provider> {
    if let Some(device) = config::get().local_device {
        let provider = local_provider(&device)?;
        let heartbeat = Heartbeat::start(&provider).await;
        return Ok(Provider::Local {
            provider,
            _heartbeat: heartbeat,
        });
    }

    let device = usb_devices()
        .await?
        .into_iter()
        .find(|d| udid.is_none_or(|udid| d.udid == udid))
        .ok_or_else(|| {
            anyhow!("No device found. Connect your iPhone or iPad with a cable and unlock it.")
        })?;
    Ok(Provider::Usb(
        device.to_provider(UsbmuxdAddr::from_env_var()?, LABEL),
    ))
}
