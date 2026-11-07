//! nimbus-helper: the sideloading engine behind Nimbus.
//!
//! The Mac app runs this binary and exchanges one JSON object per line with it.
//!
//! Commands:
//!   nimbus-helper client-info   prints the identity Nimbus reports to Apple
//!   nimbus-helper devices       prints the connected devices
//!   nimbus-helper install       reads an install request from stdin, then answers prompts
//!
//! Events (stdout): {"event": "log" | "progress" | "two_factor" | "signed_in" | "select_team" |
//!                   "revoke_certs" | "done" | "error" | "devices" | "client_info", ...}
//! Replies (stdin): {"code": "123456"} | {"action": "resend" | "devices" | "sms" | "abort", "number_id": 1}
//!                  {"team_id": "..."} | {"serials": ["..."]}

mod client_info;
mod io;

use anyhow::{Context, Result, anyhow};
use idevice::usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice};
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{
        certificates::DevelopmentCertificate, developer_session::DeveloperSession,
        teams::DeveloperTeam,
    },
    sideload::{
        SideloaderBuilder, TeamSelection,
        builder::{ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior},
    },
    util::{
        callbacks::ExtensionsBehaviorCallbackBox, device::IdeviceInfo,
        keyring_storage::KeyringStorage,
    },
};
use rootcause::Report;
use serde::Deserialize;
use serde_json::json;
use std::path::PathBuf;

const STORAGE_SERVICE: &str = "Nimbus";
const MACHINE_NAME: &str = "Nimbus";

#[derive(Deserialize)]
struct InstallRequest {
    apple_id: String,
    password: String,
    ipa: PathBuf,
    udid: Option<String>,
    anisette_url: Option<String>,
    #[serde(default)]
    increased_memory_limit: bool,
}

#[tokio::main]
async fn main() {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Failed to install rustls crypto provider");
    let _ = isideload::init();
    io::init_logging();

    let command = std::env::args().nth(1).unwrap_or_default();
    let result = match command.as_str() {
        "client-info" => print_client_info(),
        "devices" => list_devices().await,
        "install" => install().await,
        _ => Err(anyhow!(
            "Unknown command '{command}'. Use client-info, devices or install."
        )),
    };

    if let Err(error) = result {
        io::emit(json!({ "event": "error", "message": explain(&format!("{error:#}")) }));
        std::process::exit(1);
    }
}

/// Puts a plain-language hint in front of errors people run into most.
fn explain(message: &str) -> String {
    let hint = if message.contains("429") {
        "Apple is rate limiting sign-ins right now (HTTP 429). Wait at least an hour before trying again; every new attempt resets the clock."
    } else if message.contains("-20101") || message.to_lowercase().contains("incorrect") {
        "Your Apple ID or password is incorrect."
    } else if message.contains("-22411") || message.contains("-22421") {
        "Apple didn't accept the verification code. Request a new one and try again."
    } else if message.to_lowercase().contains("usbmuxd") {
        "Can't talk to your device. Connect it with a cable, unlock it and tap Trust."
    } else if message.contains("3 apps") || message.contains("maximum number of apps") {
        "A free Apple ID can have at most 3 sideloaded apps at once. Remove one and try again."
    } else {
        return message.to_string();
    };
    format!("{hint}\n\nDetails: {message}")
}

fn print_client_info() -> Result<()> {
    let info = client_info::current_mac();
    io::emit(json!({
        "event": "client_info",
        "client_info": info.client_info,
        "user_agent": info.user_agent,
    }));
    Ok(())
}

async fn connected_devices() -> Result<Vec<UsbmuxdDevice>> {
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

async fn list_devices() -> Result<()> {
    let mut list = Vec::new();
    for device in connected_devices().await? {
        let connection = match device.connection_type {
            Connection::Usb => "usb",
            Connection::Network(_) => "wifi",
            Connection::Unknown(_) => "unknown",
        };
        let provider = device.to_provider(UsbmuxdAddr::from_env_var()?, "nimbus");
        let name = IdeviceInfo::from_device(&provider)
            .await
            .map(|info| info.name)
            .unwrap_or_else(|_| "Unnamed device".to_string());
        list.push(json!({ "udid": device.udid, "name": name, "connection": connection }));
    }
    io::emit(json!({ "event": "devices", "devices": list }));
    Ok(())
}

async fn install() -> Result<()> {
    let request: InstallRequest =
        serde_json::from_value(io::read_reply()?).context("Invalid install request")?;
    if !request.ipa.is_file() {
        return Err(anyhow!("Can't find {}", request.ipa.display()));
    }
    let apple_id = request.apple_id.trim().to_lowercase();

    // Find the device before signing in, so a missing device doesn't cost a sign-in attempt.
    io::log("Looking for your device…");
    let device = connected_devices()
        .await?
        .into_iter()
        .find(|d| request.udid.as_deref().is_none_or(|udid| d.udid == udid))
        .ok_or_else(|| {
            anyhow!("No device found. Connect your iPhone or iPad with a cable and unlock it.")
        })?;
    let provider = device.to_provider(UsbmuxdAddr::from_env_var()?, "nimbus");

    let identity = client_info::current_mac();
    io::log(format!("Signing in as {}…", identity.client_info));

    let mut anisette = RemoteV3AnisetteProvider::default()
        .map_err(|e| anyhow!("{e}"))?
        .set_serial_number("0".to_string())
        .set_storage(Box::new(KeyringStorage::new(STORAGE_SERVICE.to_string())))
        .set_client_info_override(Some(identity));
    if let Some(url) = request.anisette_url.as_deref().filter(|u| !u.is_empty()) {
        anisette = anisette.set_url(url);
    }

    let mut account = AppleAccount::builder(&apple_id)
        .anisette_provider(anisette)
        // Retrying a 429 straight away only extends Apple's block.
        .err_429_retries(None)
        .login(&request.password, two_factor_prompt)
        .await
        .map_err(|e| anyhow!("Sign-in failed: {e}"))?;
    io::emit(json!({ "event": "signed_in" }));

    let session = DeveloperSession::from_account(&mut account)
        .await
        .map_err(|e| anyhow!("Couldn't open a developer session: {e}"))?;

    let mut sideloader = SideloaderBuilder::<_, ExtensionsBehaviorCallbackBox>::new(
        session,
        apple_id,
    )
    .team_selection(TeamSelection::PromptOnce(team_prompt))
    .max_certs_behavior(MaxCertsBehavior::Prompt(revoke_certs_prompt))
    .extensions_behavior(ExtensionsBehaviorSelection::Fixed(
        ExtensionsBehavior::ReuseMain,
    ))
    .storage(Box::new(KeyringStorage::new(STORAGE_SERVICE.to_string())))
    .machine_name(MACHINE_NAME.to_string())
    .build();

    io::log("Signing and installing the app…");
    sideloader
        .install_app(
            &provider,
            request.ipa,
            request.increased_memory_limit,
            Some(|progress: f32| async move {
                io::emit(json!({ "event": "progress", "value": progress }));
            }),
            None,
        )
        .await
        .map_err(|e| anyhow!("Installing failed: {e}"))?;

    io::emit(json!({ "event": "done" }));
    Ok(())
}

async fn ask_async(event: serde_json::Value) -> Result<serde_json::Value, Report> {
    tokio::task::spawn_blocking(move || io::ask(event))
        .await
        .map_err(|e| rootcause::report!("{e}"))?
        .map_err(|e| rootcause::report!("{e}"))
}

async fn two_factor_prompt(
    params: TwoFactorCallbackParams,
) -> Result<TwoFactorCallbackResponse, Report> {
    let numbers: Vec<_> = params
        .numbers
        .iter()
        .map(|n| json!({ "id": n.id, "number": n.number_with_dial_code }))
        .collect();
    let reply = ask_async(json!({
        "event": "two_factor",
        "sms": params.sms,
        "unknown": params.unknown,
        "numbers": numbers,
        "selected_number_id": params.selected_number_id,
        "last_error": params.last_error,
    }))
    .await?;

    Ok(match reply["action"].as_str() {
        Some("resend") => TwoFactorCallbackResponse::ResendCode,
        Some("devices") => TwoFactorCallbackResponse::SendToDevices,
        Some("sms") => {
            TwoFactorCallbackResponse::SendSms(reply["number_id"].as_u64().unwrap_or(1) as u32)
        }
        Some("abort") => TwoFactorCallbackResponse::Abort,
        _ => TwoFactorCallbackResponse::SubmitCode(
            reply["code"].as_str().unwrap_or_default().trim().to_string(),
        ),
    })
}

fn team_prompt(teams: &Vec<DeveloperTeam>) -> Option<String> {
    let list: Vec<_> = teams
        .iter()
        .map(|t| json!({ "id": t.team_id, "name": t.name, "type": t.r#type }))
        .collect();
    let reply = io::ask(json!({ "event": "select_team", "teams": list })).ok()?;
    reply["team_id"].as_str().map(str::to_string)
}

async fn revoke_certs_prompt(
    certs: Vec<DevelopmentCertificate>,
) -> Result<Option<Vec<String>>, Report> {
    let list: Vec<_> = certs
        .iter()
        .map(|c| {
            json!({
                "serial": c.serial_number,
                "name": c.name,
                "machine": c.machine_name,
                "expires": c.expiration_date.map(|d| d.to_xml_format()),
            })
        })
        .collect();
    let reply = ask_async(json!({ "event": "revoke_certs", "certificates": list })).await?;

    let serials: Vec<String> = reply["serials"]
        .as_array()
        .map(|a| a.iter().filter_map(|s| s.as_str().map(str::to_string)).collect())
        .unwrap_or_default();
    Ok((!serials.is_empty()).then_some(serials))
}
