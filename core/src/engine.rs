//! The commands of the sideloading engine. See lib.rs for the protocol.

use crate::device::{self, Link};
use crate::{client_info, io};
use anyhow::{Context, Result, anyhow};
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{
        app_ids::AppIdsApi, certificates::DevelopmentCertificate,
        developer_session::DeveloperSession, devices::DevicesApi, teams::DeveloperTeam,
    },
    sideload::{
        SideloaderBuilder, TeamSelection,
        builder::{ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior},
        sideloader::Sideloader,
    },
    util::callbacks::{ExtensionsBehaviorCallbackBox, MaxCertsCallback},
};
use rootcause::Report;
use serde::Deserialize;
use serde_json::json;
use std::path::{Path, PathBuf};

const MACHINE_NAME: &str = "Nimbus";

#[derive(Deserialize)]
struct InstallRequest {
    apple_id: String,
    password: String,
    /// Installed one after another, with a single sign-in.
    apps: Vec<PathBuf>,
    udid: Option<String>,
    anisette_url: Option<String>,
    #[serde(default)]
    increased_memory_limit: bool,
    /// Where to keep each app as it was signed, to put an archived app back without signing in.
    signed_cache: Option<PathBuf>,
    /// Apps among `apps` that are archived: they're signed and kept in `signed_cache`, so they
    /// can go back quickly, but not installed, since they're not meant to take up a slot.
    #[serde(default)]
    sign_only: Vec<PathBuf>,
}

/// Runs one command and reports a failure as an "error" event. Returns whether it succeeded.
pub async fn run(command: &str, args: &[String]) -> bool {
    init();
    let result = dispatch(command, args).await;
    if let Err(error) = &result {
        io::emit(json!({ "event": "error", "message": explain(&format!("{error:#}")) }));
    }
    result.is_ok()
}

fn init() {
    static INIT: std::sync::Once = std::sync::Once::new();
    INIT.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let _ = isideload::init();
        io::init_logging();
    });
}

async fn dispatch(command: &str, args: &[String]) -> Result<()> {
    let arg = |index: usize| {
        args.get(index)
            .map(String::as_str)
            .ok_or_else(|| anyhow!("Missing argument {}", index + 2))
    };
    match command {
        "client-info" => print_client_info(),
        "devices" => list_devices().await,
        "apps" => list_apps(arg(0)?).await,
        "uninstall" => uninstall(arg(0)?, arg(1)?).await,
        "install" => install().await,
        "diagnose" => device::diagnose().await,
        "deactivate" => crate::profiles::deactivate(arg(0)?, arg(1)?, arg(2)?).await,
        "activate" => crate::profiles::activate(arg(0)?, arg(1)?, arg(2)?).await,
        "wake" => crate::profiles::wake(arg(0)?, arg(1)?, arg(2)?).await,
        "archive" => crate::archive::archive(arg(0)?, arg(1)?, arg(2)?).await,
        "unarchive" => crate::archive::unarchive(arg(0)?, arg(1)?, arg(2)?, arg(3)?).await,
        "swap" => {
            crate::archive::swap(
                arg(0)?,
                arg(1)?,
                arg(2)?,
                arg(3)?,
                args.get(4).map(String::as_str),
            )
            .await
        }
        "backup" => crate::archive::backup(arg(0)?, arg(1)?, arg(2)?).await,
        "restore" => crate::archive::restore(arg(0)?, arg(1)?, arg(2)?).await,
        "inspect" => inspect(Path::new(arg(0)?)),
        "jit" => crate::jit::enable(arg(0)?, arg(1)?).await,
        "ddi" => ddi(arg(0)?, args.get(1).map(String::as_str)).await,
        #[cfg(target_os = "macos")]
        "setup-phone" => {
            crate::setup::setup_phone(arg(0)?, arg(1)?, args.get(2).map(String::as_str)).await
        }
        #[cfg(target_os = "macos")]
        "phone-status" => crate::setup::phone_status(arg(0)?, arg(1)?).await,
        #[cfg(target_os = "macos")]
        "sync-phone" => crate::setup::sync_phone(arg(0)?, arg(1)?).await,
        #[cfg(target_os = "macos")]
        "crash-log" => crate::setup::crash_log(arg(0)?, arg(1)?).await,
        #[cfg(target_os = "macos")]
        "pairing-file" => crate::setup::save_pairing_file(arg(0)?, arg(1)?).await,
        _ => Err(anyhow!(
            "Unknown command '{command}'. Use client-info, devices, apps, uninstall, install or setup-phone."
        )),
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
    } else if device::is_local() && message.contains("Can't connect to") {
        "Can't reach this device. Turn on LocalDevVPN and try again."
    } else if message.contains("does not have pairing file") && !device::is_local() {
        "Your device doesn't trust this Mac anymore. Unplug the cable, plug it back in, and tap Trust on your device."
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
    let info = client_info::current();
    io::emit(json!({
        "event": "client_info",
        "client_info": info.client_info,
        "user_agent": info.user_agent,
    }));
    Ok(())
}

async fn list_devices() -> Result<()> {
    io::emit(json!({ "event": "devices", "devices": device::list().await? }));
    Ok(())
}

/// Lists apps that were installed with a development certificate, i.e. sideloaded apps.
/// These are the apps that count towards the limit of 3 on a free Apple ID.
async fn list_apps(udid: &str) -> Result<()> {
    let mut link = device::link_for(Some(udid)).await?;
    let mut client = link
        .installation_proxy()
        .await
        .map_err(|e| anyhow!("Can't read the apps on your device: {e}"))?;
    let apps = client
        .get_apps(Some("User"), None)
        .await
        .map_err(|e| anyhow!("Can't read the apps on your device: {e}"))?;

    // An app without a profile is deactivated: still there, but it won't open and doesn't
    // count towards the limit. When the profiles can't be read, that stays unknown.
    let profiles = crate::profiles::installed(&mut link).await.ok();

    let mut list = Vec::new();
    for (bundle_id, info) in apps {
        let Some(info) = info.as_dictionary() else {
            continue;
        };
        let text = |key: &str| {
            info.get(key)
                .and_then(|v| v.as_string())
                .map(str::to_string)
        };
        let signer = text("SignerIdentity").unwrap_or_default();
        if !(signer.starts_with("Apple Development") || signer.starts_with("iPhone Developer")) {
            continue;
        }
        list.push(json!({
            "bundle_id": bundle_id,
            "name": text("CFBundleDisplayName").or_else(|| text("CFBundleName")).unwrap_or(bundle_id.clone()),
            "version": text("CFBundleShortVersionString"),
            "signer": signer,
            "active": profiles.as_ref().map(|profiles| {
                profiles.iter().any(|profile| profile.covers(&bundle_id))
            }),
        }));
    }
    list.sort_by_key(|a| a["name"].as_str().unwrap_or_default().to_lowercase());
    io::emit(json!({ "event": "apps", "apps": list }));
    Ok(())
}

async fn uninstall(udid: &str, bundle_id: &str) -> Result<()> {
    let mut link = device::link_for(Some(udid)).await?;
    let mut client = link
        .installation_proxy()
        .await
        .map_err(|e| anyhow!("Can't reach your device: {e}"))?;
    client
        .uninstall(bundle_id, None)
        .await
        .map_err(|e| anyhow!("Couldn't remove {bundle_id}: {e}"))?;
    io::emit(json!({ "event": "uninstalled", "bundle_id": bundle_id }));
    Ok(())
}

async fn install() -> Result<()> {
    let request: InstallRequest =
        serde_json::from_value(io::read_reply()?).context("Invalid install request")?;
    if request.apps.is_empty() {
        return Err(anyhow!("No apps to install."));
    }
    if !request.apps.iter().any(|path| path.is_file()) {
        return Err(anyhow!("Can't find the app file."));
    }
    let apple_id = request.apple_id.trim().to_lowercase();

    // Find the device before signing in, so a missing device doesn't cost a sign-in attempt.
    io::log("Looking for your device…");
    let mut link = device::link_for(request.udid.as_deref()).await?;
    let device = link.info().await?;

    let identity = client_info::current();
    io::log(format!("Signing in as {}…", identity.client_info));

    let mut anisette = RemoteV3AnisetteProvider::default()
        .map_err(|e| anyhow!("{e}"))?
        .set_serial_number("0".to_string())
        .set_storage(crate::storage::new())
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

    let mut sideloader =
        SideloaderBuilder::<_, ExtensionsBehaviorCallbackBox>::new(session, apple_id)
            .team_selection(TeamSelection::PromptOnce(team_prompt))
            .max_certs_behavior(MaxCertsBehavior::Prompt(revoke_certs_prompt))
            .extensions_behavior(ExtensionsBehaviorSelection::Fixed(
                ExtensionsBehavior::ReuseMain,
            ))
            .storage(crate::storage::new())
            .machine_name(MACHINE_NAME.to_string())
            .build();

    let team = sideloader
        .get_team()
        .await
        .map_err(|e| anyhow!("Couldn't load your developer team: {e}"))?;
    sideloader
        .get_dev_session()
        .ensure_device_registered(&team, &device.name, &device.udid, None)
        .await
        .map_err(|e| anyhow!("Couldn't register your device with Apple: {e}"))?;

    let count = request.apps.len();
    let mut failures = 0;
    for (index, path) in request.apps.into_iter().enumerate() {
        io::emit(json!({ "event": "installing", "index": index, "count": count }));
        // A missing file only skips this app, so the other apps still get refreshed.
        let result = if !path.is_file() {
            Err(anyhow!("Can't find {}", path.display()))
        } else {
            let install = !request.sign_only.contains(&path);
            install_one(
                &mut sideloader,
                &mut link,
                &team,
                &path,
                request.increased_memory_limit,
                request.signed_cache.as_deref(),
                install,
                index,
                count,
            )
            .await
        };
        match result {
            Ok(installed) => io::emit(installed),
            Err(error) => {
                failures += 1;
                io::emit(json!({
                    "event": "app_failed",
                    "index": index,
                    "message": explain(&format!("{error:#}")),
                }));
            }
        }
    }

    if let Ok(ids) = sideloader.get_dev_session().list_app_ids(&team, None).await {
        io::emit(json!({
            "event": "limits",
            "team_id": team.team_id,
            "app_ids_used": ids.app_ids.len(),
            "app_ids_max": ids.max_quantity,
            "app_ids_available": ids.available_quantity,
        }));
    }

    if failures == count {
        return Err(anyhow!(if count == 1 {
            "The app couldn't be installed."
        } else {
            "None of the apps could be installed."
        }));
    }
    io::emit(json!({ "event": "done" }));
    Ok(())
}

async fn install_one<C: MaxCertsCallback>(
    sideloader: &mut Sideloader<C, ExtensionsBehaviorCallbackBox>,
    link: &mut Link,
    team: &DeveloperTeam,
    ipa: &Path,
    increased_memory_limit: bool,
    signed_cache: Option<&Path>,
    install: bool,
    index: usize,
    count: usize,
) -> Result<serde_json::Value> {
    // Signing is the first half of the work for each app, transferring and installing the second.
    let overall = move |part: f64| (index as f64 + part.clamp(0.0, 1.0)) / count as f64;

    // Apps made for AltStore are told their app group before they're signed.
    let unpacked = unpack_for_app_groups(ipa, &team.team_id)?;

    io::log("Signing…");
    let signing = sideloader
        .sign_app(
            unpacked.clone().unwrap_or_else(|| ipa.to_path_buf()),
            Some(team.clone()),
            increased_memory_limit,
            Some(|p: f32| async move {
                io::emit(json!({ "event": "progress", "value": overall(p as f64 * 0.5) }));
            }),
            None,
            None,
        )
        .await
        .map_err(|e| anyhow!("Signing failed: {e}"));
    let (signed, _) = match signing {
        Ok(signed) => signed,
        Err(error) => {
            if let Some(app) = &unpacked {
                remove_unpacked(app);
            }
            return Err(error);
        }
    };

    let info = signed_app_info(&signed);

    let result = if install {
        io::log("Installing…");
        link.install(&signed, |p| {
            io::emit(json!({ "event": "progress", "value": overall(0.5 + p as f64 / 200.0) }));
        })
        .await
        .map_err(|e| anyhow!("Installing failed: {e}"))
    } else if signed_cache.is_none() {
        Err(anyhow!("Nowhere to keep the signed app."))
    } else {
        io::log("Keeping the signed app for when it's restored…");
        Ok(())
    };

    // Keep the signed app only when it's really on the device now, or meant to be kept.
    if let (Ok(()), Ok(info), Some(cache)) = (&result, &info, signed_cache)
        && let Some(bundle_id) = info["bundle_id"].as_str()
    {
        let kept = crate::archive::signed_app(cache, bundle_id);
        let _ = std::fs::remove_dir_all(&kept);
        if let Err(error) = crate::archive::copy_folder(&signed, &kept) {
            tracing::warn!("Couldn't keep the signed app: {error}");
            let _ = std::fs::remove_dir_all(&kept);
        }
    }
    remove_unpacked(&signed);
    result?;

    let mut installed = info?;
    installed["event"] = json!("installed");
    installed["index"] = json!(index);
    installed["kept_only"] = json!(!install);
    Ok(installed)
}

/// Shows whether the developer disk image is mounted, or mounts or unmounts it.
async fn ddi(udid: &str, action: Option<&str>) -> Result<()> {
    let mut tunnel = device::tunnel_for(Some(udid)).await?;
    match action {
        Some("mount") => crate::ddi::mount(&mut tunnel).await?,
        Some("unmount") => crate::ddi::unmount(&mut tunnel).await?,
        _ => {}
    }
    if action.is_some() {
        tunnel = device::tunnel_for(Some(udid)).await?;
    }
    io::emit(json!({
        "event": "ddi",
        "mounted": crate::ddi::is_mounted(&tunnel),
        "image": crate::ddi::image_folder().is_some(),
    }));
    Ok(())
}

/// Removes the folder an IPA was unpacked into, given the app inside it:
/// <temp>/<name>.ipa_extracted/Payload/<name>.app. sign_app unpacks to the same place.
fn remove_unpacked(app: &Path) {
    if let Some(extracted) = app.parent().and_then(Path::parent)
        && extracted.starts_with(std::env::temp_dir())
        && extracted.to_string_lossy().ends_with("_extracted")
    {
        let _ = std::fs::remove_dir_all(extracted);
    }
}

/// The name of Payload/<App>.app/Info.plist in an IPA: the app's own, not the Info.plist
/// files of its frameworks and extensions.
fn main_info_plist<R: std::io::Read + std::io::Seek>(
    archive: &zip::ZipArchive<R>,
) -> Option<String> {
    archive
        .file_names()
        .find(|name| {
            let parts: Vec<&str> = name.split('/').collect();
            parts.len() == 3
                && parts[0] == "Payload"
                && parts[1].ends_with(".app")
                && parts[2] == "Info.plist"
        })
        .map(str::to_string)
}

/// Apps made for AltStore, such as Clip and Delta, look up their app group in their
/// Info.plist under ALTAppGroups, and crash when the group there isn't one they're signed for.
/// Signing gives an app its own group, named after its new bundle ID, so that name has to go
/// into the Info.plist before signing. Unpacks such an app, writes the group into it and its
/// extensions, and returns the app's folder to sign. Returns None for every other app.
fn unpack_for_app_groups(ipa: &Path, team_id: &str) -> Result<Option<PathBuf>> {
    use std::io::Read;

    let mut archive = zip::ZipArchive::new(std::fs::File::open(ipa)?)
        .map_err(|_| anyhow!("This isn't a valid app (.ipa) file."))?;
    let Some(entry) = main_info_plist(&archive) else {
        return Ok(None);
    };
    let mut data = Vec::new();
    archive.by_name(&entry)?.read_to_end(&mut data)?;
    let Ok(info) = plist::from_bytes::<plist::Dictionary>(&data) else {
        return Ok(None);
    };
    let (true, Some(bundle_id)) = (
        info.contains_key("ALTAppGroups"),
        info.get("CFBundleIdentifier").and_then(|v| v.as_string()),
    ) else {
        return Ok(None);
    };
    // The same name sign_app gives the group: "group." and the signed bundle ID.
    let group = format!("group.{bundle_id}.{team_id}");

    let name = ipa.file_name().unwrap_or_default().to_string_lossy();
    let folder = std::env::temp_dir().join(format!("{name}_extracted"));
    let _ = std::fs::remove_dir_all(&folder);
    std::fs::create_dir_all(&folder)?;
    archive
        .extract(&folder)
        .context("Couldn't unpack the app")?;

    let app = folder.join(Path::new(&entry).parent().unwrap_or(Path::new("")));
    let mut plists = vec![app.join("Info.plist")];
    if let Ok(extensions) = std::fs::read_dir(app.join("PlugIns")) {
        plists.extend(extensions.flatten().map(|e| e.path().join("Info.plist")));
    }
    for path in plists.iter().filter(|path| path.is_file()) {
        let mut info: plist::Dictionary =
            plist::from_file(path).context("Couldn't read the app's Info.plist")?;
        info.insert(
            "ALTAppGroups".to_string(),
            plist::Value::Array(vec![plist::Value::String(group.clone())]),
        );
        plist::to_file_binary(path, &info).context("Couldn't change the app's Info.plist")?;
    }
    Ok(Some(app))
}

/// Reads what an IPA contains without unpacking it, to check a file before signing in for it:
/// {"event": "ipa", "bundle_id", "name", "version", "minimum_os"}.
fn inspect(ipa: &Path) -> Result<()> {
    use std::io::Read;

    let not_an_app = || anyhow!("This isn't a valid app (.ipa) file.");
    let file = std::fs::File::open(ipa).context("Can't open the file")?;
    let mut archive = zip::ZipArchive::new(file).map_err(|_| not_an_app())?;
    let entry = main_info_plist(&archive).ok_or_else(not_an_app)?;
    let mut data = Vec::new();
    archive
        .by_name(&entry)
        .map_err(|_| not_an_app())?
        .take(4 * 1024 * 1024)
        .read_to_end(&mut data)
        .map_err(|_| not_an_app())?;
    let info: plist::Dictionary = plist::from_bytes(&data).map_err(|_| not_an_app())?;
    let text = |key: &str| {
        info.get(key)
            .and_then(|v| v.as_string())
            .map(str::to_string)
    };
    let bundle_id = text("CFBundleIdentifier").ok_or_else(not_an_app)?;

    io::emit(json!({
        "event": "ipa",
        "bundle_id": bundle_id,
        "name": text("CFBundleDisplayName").or_else(|| text("CFBundleName")),
        "version": text("CFBundleShortVersionString"),
        "minimum_os": text("MinimumOSVersion"),
    }));
    Ok(())
}

/// Reads the bundle ID, name, version and expiry date from a signed app.
fn signed_app_info(app: &Path) -> Result<serde_json::Value> {
    let info: plist::Dictionary = plist::from_file(app.join("Info.plist"))
        .context("Can't read the signed app's Info.plist")?;
    let text = |key: &str| {
        info.get(key)
            .and_then(|v| v.as_string())
            .map(str::to_string)
    };

    // The profile is a signed CMS blob with an XML plist inside.
    let profile = std::fs::read(app.join("embedded.mobileprovision"))
        .context("The signed app has no provisioning profile")?;
    let start = profile
        .windows(5)
        .position(|w| w == b"<?xml")
        .context("Unreadable provisioning profile")?;
    let end = profile
        .windows(8)
        .rposition(|w| w == b"</plist>")
        .context("Unreadable provisioning profile")?
        + 8;
    let profile: plist::Dictionary =
        plist::from_bytes(&profile[start..end]).context("Unreadable provisioning profile")?;
    let expires = profile
        .get("ExpirationDate")
        .and_then(|v| v.as_date())
        .map(|d| d.to_xml_format());

    Ok(json!({
        "bundle_id": text("CFBundleIdentifier"),
        "name": text("CFBundleDisplayName").or_else(|| text("CFBundleName")),
        "version": text("CFBundleShortVersionString"),
        "expires": expires,
    }))
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
            reply["code"]
                .as_str()
                .unwrap_or_default()
                .trim()
                .to_string(),
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
        .map(|a| {
            a.iter()
                .filter_map(|s| s.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    Ok((!serials.is_empty()).then_some(serials))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn altstore_apps_get_their_app_group() {
        // Clip from AltStore's source, when it's there; the test needs a real app.
        let Ok(ipa) = std::env::var("NIMBUS_TEST_IPA") else {
            return;
        };
        let app = unpack_for_app_groups(Path::new(&ipa), "TEAM123456")
            .unwrap()
            .expect("an app with ALTAppGroups");
        let info: plist::Dictionary = plist::from_file(app.join("Info.plist")).unwrap();
        let bundle_id = info["CFBundleIdentifier"].as_string().unwrap();
        let expected = plist::Value::Array(vec![plist::Value::String(format!(
            "group.{bundle_id}.TEAM123456"
        ))]);
        assert_eq!(info["ALTAppGroups"], expected);
        for extension in std::fs::read_dir(app.join("PlugIns")).unwrap().flatten() {
            let info: plist::Dictionary =
                plist::from_file(extension.path().join("Info.plist")).unwrap();
            assert_eq!(info["ALTAppGroups"], expected);
        }
        remove_unpacked(&app);
        assert!(!app.exists());
    }
}
