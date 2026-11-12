//! Setting up Nimbus on an iPhone or iPad from the Mac.
//!
//! The iPhone app talks to its own device through a loopback VPN, and needs a remote pairing
//! file to be allowed in. The Mac creates one and puts it in the app's Documents folder,
//! together with the Mac's identity so the app signs in to Apple the same way the Mac does.

use crate::{client_info, device, io};
use anyhow::{Result, anyhow};
use idevice::{
    IdeviceError, IdeviceService,
    afc::{AfcClient, opcode::AfcFopenMode},
    house_arrest::HouseArrestClient,
    provider::{IdeviceProvider, UsbmuxdProvider},
    remote_pairing::{RemotePairingLockdownService, RpPairingFile},
};
use serde_json::json;
use std::time::Duration;

const PAIRING_FILE: &str = "/Documents/rp_pairing.plist";
const IDENTITY_FILE: &str = "/Documents/identity.json";
const SIGNING_FILE: &str = "/Documents/signing.json";
const LIBRARY_FILE: &str = "/Documents/library.json";
const IPA_FOLDER: &str = "/Documents/IPAs";
/// Written by Nimbus on the device: until when the apps it refreshed itself keep working.
const REFRESHED_FILE: &str = "/Documents/refreshed.json";
/// The lockdown pairing file of earlier versions, which devices no longer accept from themselves.
const OLD_PAIRING_FILE: &str = "/Documents/pairing.plist";
const PAIRING_TIMEOUT: Duration = Duration::from_secs(60);

/// The name the pairing-file command pairs under. A device keeps one pairing per name, so
/// pairing as "Nimbus" here would replace the pairing of Nimbus on the device and lock it out.
const TEST_HOST_NAME: &str = "Nimbus (Mac)";

/// Pairs with the device for remote connections and returns the pairing file.
async fn pair(provider: &UsbmuxdProvider, host_name: &str) -> Result<Vec<u8>> {
    let service = RemotePairingLockdownService::connect(provider as &dyn IdeviceProvider)
        .await
        .map_err(|e| {
            anyhow!("Can't start pairing. Connect your device with a cable and unlock it. ({e})")
        })?;
    let mut client = service
        .into_client(host_name)
        .map_err(|e| anyhow!("Can't start pairing: {e}"))?;

    let mut pairing = RpPairingFile::generate(host_name);
    // This Mac is already trusted, so the device doesn't ask for a code.
    tokio::time::timeout(
        PAIRING_TIMEOUT,
        client.connect(&mut pairing, async || "000000".to_string()),
    )
    .await
    .map_err(|_| anyhow!("Your device didn't answer. Unlock it and try again."))?
    .map_err(|e| anyhow!("Couldn't pair with your device: {e} ({e:?})"))?;
    Ok(pairing.to_bytes())
}

/// What lets Nimbus on the device sign in and sign like this Mac does, as stored values by key:
/// the signing key of the Apple ID's certificate and the state that identifies this Mac to
/// Apple. With them the device needs no certificate of its own, which a free Apple ID has
/// too few of, and Apple sees one machine instead of two.
fn signing_handoff(apple_id: &str) -> Option<Vec<u8>> {
    let storage = crate::storage::new();
    let key_name = crate::storage::signing_key_name(apple_id);
    let key = storage.retrieve(&key_name).ok().flatten()?;
    let mut values = serde_json::Map::new();
    values.insert(key_name, json!(key));
    if let Ok(Some(state)) = storage.retrieve(crate::storage::ANISETTE_STATE_KEY) {
        values.insert(crate::storage::ANISETTE_STATE_KEY.to_string(), json!(state));
    }
    serde_json::to_vec(&values).ok()
}

pub async fn setup_phone(udid: &str, bundle_id: &str, apple_id: Option<&str>) -> Result<()> {
    let provider = device::usb_provider(udid).await?;

    io::log("Creating a pairing file…");
    let pairing = pair(&provider, device::HOST_NAME).await?;

    io::log("Sending the pairing file to Nimbus on your device…");
    let identity = client_info::current();
    let identity = serde_json::to_vec(&json!({
        "client_info": identity.client_info,
        "user_agent": identity.user_agent,
    }))?;

    let mut documents = HouseArrestClient::connect(&provider as &dyn IdeviceProvider)
        .await
        .map_err(|e| anyhow!("Can't reach the apps on your device: {e}"))?
        .vend_documents(bundle_id)
        .await
        .map_err(|e| anyhow!("Can't open Nimbus on your device. Is it installed? ({e})"))?;
    write(&mut documents, PAIRING_FILE, &pairing).await?;
    write(&mut documents, IDENTITY_FILE, &identity).await?;
    match apple_id.and_then(signing_handoff) {
        Some(signing) => {
            write(&mut documents, SIGNING_FILE, &signing).await?;
            io::log("Sent this Mac's signing key, so your device signs apps the same way.");
        }
        None => io::log("This Mac has no signing key for your Apple ID yet, so none was sent."),
    }
    let _ = documents.remove(OLD_PAIRING_FILE).await;

    io::emit(json!({ "event": "phone_ready" }));
    Ok(())
}

#[derive(serde::Deserialize)]
struct SyncRequest {
    /// The apps Nimbus on the device can refresh, as the JSON it reads.
    library: String,
    files: Vec<SyncFile>,
}

#[derive(serde::Deserialize)]
struct SyncFile {
    path: std::path::PathBuf,
    name: String,
}

/// Copies the apps this Mac installed to Nimbus on the device, so it can refresh them itself.
/// Reads which ones from a request, the way `install` does.
pub async fn sync_phone(udid: &str, bundle_id: &str) -> Result<()> {
    use anyhow::Context;
    use std::io::Read;

    let request: SyncRequest =
        serde_json::from_value(io::read_reply()?).context("Invalid sync request")?;
    let provider = device::usb_provider(udid).await?;
    let mut documents = HouseArrestClient::connect(&provider as &dyn IdeviceProvider)
        .await
        .map_err(|e| anyhow!("Can't reach the apps on your device: {e}"))?
        .vend_documents(bundle_id)
        .await
        .map_err(|e| anyhow!("Can't open Nimbus on your device. Is it installed? ({e})"))?;
    let failed = |e: IdeviceError| anyhow!("Couldn't send a file to your device: {e}");

    let _ = documents.mk_dir(IPA_FOLDER).await;
    let existing = documents.list_dir(IPA_FOLDER).await.unwrap_or_default();
    // Apps that are gone from this Mac's list don't need to take up space on the device.
    for name in existing.iter().filter(|name| !name.starts_with('.')) {
        if !request.files.iter().any(|file| &file.name == name) {
            let _ = documents.remove(format!("{IPA_FOLDER}/{name}")).await;
        }
    }

    let total: u64 = request
        .files
        .iter()
        .filter_map(|file| std::fs::metadata(&file.path).ok())
        .map(|metadata| metadata.len())
        .sum();
    let mut done = 0u64;
    for file in &request.files {
        let Ok(metadata) = std::fs::metadata(&file.path) else {
            continue;
        };
        let size = metadata.len();
        let remote = format!("{IPA_FOLDER}/{}", file.name);
        let already_there = documents
            .get_file_info(remote.clone())
            .await
            .is_ok_and(|info| info.size as u64 == size);
        if !already_there {
            let mut local = std::fs::File::open(&file.path)?;
            let mut target = documents
                .open(remote, AfcFopenMode::WrOnly)
                .await
                .map_err(failed)?;
            let mut chunk = vec![0u8; 4 * 1024 * 1024];
            let mut sent = 0u64;
            loop {
                let read = local.read(&mut chunk)?;
                if read == 0 {
                    break;
                }
                target.write_entire(&chunk[..read]).await.map_err(failed)?;
                sent += read as u64;
                io::emit(json!({
                    "event": "progress",
                    "value": (done + sent) as f64 / total.max(1) as f64,
                }));
            }
            target.close().await.map_err(failed)?;
        }
        done += size;
    }

    write(&mut documents, LIBRARY_FILE, request.library.as_bytes()).await?;
    io::emit(json!({ "event": "done" }));
    Ok(())
}

/// Reports which apps Nimbus on the device refreshed itself, so this Mac doesn't refresh
/// them again: {"event": "phone_status", "refreshed": {"<bundle ID>": "<expiry date>"}}.
pub async fn phone_status(udid: &str, bundle_id: &str) -> Result<()> {
    let provider = device::usb_provider(udid).await?;
    let mut documents = HouseArrestClient::connect(&provider as &dyn IdeviceProvider)
        .await
        .map_err(|e| anyhow!("Can't reach the apps on your device: {e}"))?
        .vend_documents(bundle_id)
        .await
        .map_err(|e| anyhow!("Can't open Nimbus on your device. Is it installed? ({e})"))?;

    // No file means the device hasn't refreshed anything yet.
    let refreshed = match documents.open(REFRESHED_FILE, AfcFopenMode::RdOnly).await {
        Ok(mut file) => {
            let data = file.read_entire().await.unwrap_or_default();
            let _ = file.close().await;
            serde_json::from_slice::<serde_json::Value>(&data).unwrap_or_else(|_| json!({}))
        }
        Err(_) => json!({}),
    };
    io::emit(json!({ "event": "phone_status", "refreshed": refreshed }));
    Ok(())
}

/// Saves a remote pairing file on this Mac, to try the connection the iPhone app makes.
pub async fn save_pairing_file(udid: &str, path: &str) -> Result<()> {
    let provider = device::usb_provider(udid).await?;
    let pairing = pair(&provider, TEST_HOST_NAME).await?;
    std::fs::write(path, pairing)?;
    io::emit(json!({ "event": "done" }));
    Ok(())
}

async fn write(documents: &mut AfcClient, path: &str, data: &[u8]) -> Result<()> {
    let failed = |e: IdeviceError| anyhow!("Couldn't send a file to your device: {e}");
    let mut file = documents
        .open(path, AfcFopenMode::WrOnly)
        .await
        .map_err(failed)?;
    file.write_entire(data).await.map_err(failed)?;
    file.close().await.map_err(failed)
}

/// Prints the newest crash report on the device whose name starts with `name`.
pub async fn crash_log(udid: &str, name: &str) -> Result<()> {
    use idevice::crashreportcopymobile::{CrashReportCopyMobileClient, flush_reports};

    let provider = device::usb_provider(udid).await?;
    // Moves fresh reports to where they can be read.
    let _ = flush_reports(&provider as &dyn IdeviceProvider).await;
    let mut reports = CrashReportCopyMobileClient::connect(&provider as &dyn IdeviceProvider)
        .await
        .map_err(|e| anyhow!("Can't read the crash reports on your device: {e}"))?;
    let mut names: Vec<String> = reports
        .ls(None)
        .await
        .map_err(|e| anyhow!("Can't list the crash reports: {e}"))?
        .into_iter()
        .filter(|report| report.starts_with(name))
        .collect();
    // Report names end in their date and time, so the last one is the newest.
    names.sort();
    let newest = names
        .pop()
        .ok_or_else(|| anyhow!("No crash reports for {name} on your device."))?;
    let text = reports
        .pull(newest.clone())
        .await
        .map_err(|e| anyhow!("Can't read {newest}: {e}"))?;
    io::emit(json!({
        "event": "crash_log",
        "name": newest,
        "text": String::from_utf8_lossy(&text),
    }));
    Ok(())
}
