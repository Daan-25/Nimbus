//! An app's data: copying it off the device and putting it back.
//!
//! A free Apple ID allows three sideloaded apps on a device, and the device counts every app
//! that's installed. The way to have more is to take one off and put it back later, and that
//! is only worth it when the app's data survives. Apps signed for development let a paired
//! computer into their data folder, which is what this uses.
//!
//! This reaches an app's own folder: its Documents and Library. It doesn't reach a shared app
//! group folder, so an app that keeps its data there comes back empty.

use crate::device::{self, Link};
use crate::io;
use anyhow::{Context, Result, anyhow};
use idevice::IdeviceError;
use idevice::afc::{AfcClient, opcode::AfcFopenMode};
use serde_json::json;
use std::io::{Read, Write};
use std::path::Path;

/// Folders the system fills in again by itself; copying them only costs time and space.
const SKIPPED: [&str; 5] = [
    "/tmp",
    "/SystemData",
    "/Library/Caches",
    "/Library/SplashBoard",
    "/Library/Saved Application State",
];
const CHUNK: usize = 4 * 1024 * 1024;

async fn container(link: &mut Link, bundle_id: &str) -> Result<AfcClient> {
    link.house_arrest()
        .await
        .map_err(|e| anyhow!("Can't reach the apps on your device: {e}"))?
        .vend_container(bundle_id)
        .await
        .map_err(|e| anyhow!("Your device doesn't let Nimbus into this app's data. ({e})"))
}

fn reading(error: IdeviceError) -> anyhow::Error {
    anyhow!("Couldn't read the app's data: {error}")
}

fn writing(error: IdeviceError) -> anyhow::Error {
    anyhow!("Couldn't write the app's data: {error}")
}

/// Copies an app's data into `folder`, replacing what was there.
pub async fn backup(udid: &str, bundle_id: &str, folder: &str) -> Result<()> {
    let mut link = device::link_for(Some(udid)).await?;
    let (files, bytes) = backup_with(&mut link, bundle_id, Path::new(folder)).await?;
    io::emit(
        json!({ "event": "backed_up", "bundle_id": bundle_id, "files": files, "bytes": bytes }),
    );
    Ok(())
}

pub async fn backup_with(link: &mut Link, bundle_id: &str, folder: &Path) -> Result<(u64, u64)> {
    let mut data = container(link, bundle_id).await?;
    // Into a folder beside the real one first, so a copy that fails halfway doesn't replace
    // a good one.
    let partial = folder.with_extension("partial");
    let _ = std::fs::remove_dir_all(&partial);
    std::fs::create_dir_all(&partial)?;

    let (mut files, mut bytes) = (0u64, 0u64);
    let mut folders = vec![String::from("/")];
    while let Some(current) = folders.pop() {
        let names = data.list_dir(current.clone()).await.map_err(reading)?;
        for name in names.iter().filter(|name| *name != "." && *name != "..") {
            let remote = if current == "/" {
                format!("/{name}")
            } else {
                format!("{current}/{name}")
            };
            if SKIPPED.contains(&remote.as_str()) {
                continue;
            }
            let local = partial.join(remote.trim_start_matches('/'));
            // Some entries can't be looked at, such as a file the app has locked. Leave those.
            let Ok(info) = data.get_file_info(remote.clone()).await else {
                continue;
            };
            match info.st_ifmt.as_str() {
                "S_IFDIR" => {
                    std::fs::create_dir_all(&local)?;
                    folders.push(remote);
                }
                "S_IFREG" => {
                    if let Some(parent) = local.parent() {
                        std::fs::create_dir_all(parent)?;
                    }
                    let mut source = data
                        .open(remote, AfcFopenMode::RdOnly)
                        .await
                        .map_err(reading)?;
                    let mut target = std::fs::File::create(&local)?;
                    let mut remaining = info.size;
                    while remaining > 0 {
                        let chunk = source.read_n(remaining.min(CHUNK)).await.map_err(reading)?;
                        if chunk.is_empty() {
                            break;
                        }
                        target.write_all(&chunk)?;
                        remaining = remaining.saturating_sub(chunk.len());
                        bytes += chunk.len() as u64;
                    }
                    source.close().await.map_err(reading)?;
                    files += 1;
                }
                // Links and other special entries aren't part of an app's own data.
                _ => {}
            }
        }
    }

    let _ = std::fs::remove_dir_all(folder);
    std::fs::rename(&partial, folder).context("Couldn't keep the app's data")?;
    Ok((files, bytes))
}

/// Copies the data in `folder` back into an app, which has to be installed.
pub async fn restore(udid: &str, bundle_id: &str, folder: &str) -> Result<()> {
    let mut link = device::link_for(Some(udid)).await?;
    let (files, bytes) = restore_with(&mut link, bundle_id, Path::new(folder)).await?;
    io::emit(
        json!({ "event": "restored", "bundle_id": bundle_id, "files": files, "bytes": bytes }),
    );
    Ok(())
}

pub async fn restore_with(link: &mut Link, bundle_id: &str, folder: &Path) -> Result<(u64, u64)> {
    if !folder.is_dir() {
        return Err(anyhow!("Nimbus has no saved data for this app."));
    }
    let mut data = container(link, bundle_id).await?;

    let (mut files, mut bytes) = (0u64, 0u64);
    let mut folders = vec![folder.to_path_buf()];
    while let Some(current) = folders.pop() {
        for entry in std::fs::read_dir(&current)?.flatten() {
            let local = entry.path();
            let Ok(relative) = local.strip_prefix(folder) else {
                continue;
            };
            let remote = format!("/{}", relative.to_string_lossy());
            if local.is_dir() {
                // It may be there already, which is fine.
                let _ = data.mk_dir(remote).await;
                folders.push(local);
            } else {
                let mut source = std::fs::File::open(&local)?;
                let mut target = data
                    .open(remote, AfcFopenMode::WrOnly)
                    .await
                    .map_err(writing)?;
                let mut chunk = vec![0u8; CHUNK];
                loop {
                    let read = source.read(&mut chunk)?;
                    if read == 0 {
                        break;
                    }
                    target.write_entire(&chunk[..read]).await.map_err(writing)?;
                    bytes += read as u64;
                }
                target.close().await.map_err(writing)?;
                files += 1;
            }
        }
    }
    Ok((files, bytes))
}

/// Where an app's data is kept while it's archived.
fn data_folder(folder: &str, bundle_id: &str) -> std::path::PathBuf {
    Path::new(folder).join(bundle_id)
}

/// Where an app is kept as it was signed.
pub fn signed_app(cache: &Path, bundle_id: &str) -> std::path::PathBuf {
    cache.join(format!("{bundle_id}.app"))
}

pub fn copy_folder(from: &Path, to: &Path) -> Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        let kind = entry.file_type()?;
        if kind.is_dir() {
            copy_folder(&entry.path(), &target)?;
        } else if kind.is_symlink() {
            std::os::unix::fs::symlink(std::fs::read_link(entry.path())?, &target)?;
        } else {
            std::fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

/// Archives an app: keeps its data in `folder` and takes the app off the device, which frees
/// its place among the three a free Apple ID allows. Nothing is removed unless the data was
/// copied first.
pub async fn archive(udid: &str, bundle_id: &str, folder: &str) -> Result<()> {
    let mut link = device::link_for(Some(udid)).await?;
    io::log("Saving the app's data…");
    let (files, bytes) = backup_with(&mut link, bundle_id, &data_folder(folder, bundle_id)).await?;

    io::log("Removing the app…");
    let mut apps = link
        .installation_proxy()
        .await
        .map_err(|e| anyhow!("Can't reach your device: {e}"))?;
    apps.uninstall(bundle_id, None)
        .await
        .map_err(|e| anyhow!("The data is saved, but the app couldn't be removed: {e}"))?;
    io::emit(
        json!({ "event": "archived", "bundle_id": bundle_id, "files": files, "bytes": bytes }),
    );
    Ok(())
}

/// Puts an archived app back from the copy that was kept when it was signed, and its data
/// with it. That takes no sign-in, as long as the signature in the copy is still good. When it
/// isn't, this fails before touching the device, and the app has to be installed afresh first.
pub async fn unarchive(udid: &str, bundle_id: &str, folder: &str, cache: &str) -> Result<()> {
    let app = signed_app(Path::new(cache), bundle_id);
    let still_good = std::fs::read(app.join("embedded.mobileprovision"))
        .is_ok_and(|profile| crate::profiles::is_valid(&profile));
    if !still_good {
        return Err(anyhow!(
            "Nimbus has no signed copy of this app that's still good, so it has to sign it again."
        ));
    }

    let mut link = device::link_for(Some(udid)).await?;
    io::log("Installing the app…");
    link.install(&app, |progress| {
        io::emit(json!({ "event": "progress", "value": progress as f64 / 100.0 * 0.7 }));
    })
    .await
    .map_err(|e| anyhow!("Installing failed: {e}"))?;

    let data = data_folder(folder, bundle_id);
    let (mut files, mut bytes) = (0, 0);
    if data.is_dir() {
        io::log("Putting the app's data back…");
        (files, bytes) = restore_with(&mut link, bundle_id, &data).await?;
        let _ = std::fs::remove_dir_all(&data);
    }
    io::emit(
        json!({ "event": "unarchived", "bundle_id": bundle_id, "files": files, "bytes": bytes }),
    );
    Ok(())
}
