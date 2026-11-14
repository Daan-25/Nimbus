//! Provisioning profiles: what lets a sideloaded app run on a device.
//!
//! Taking an app's profile away leaves the app and its data in place, but it won't open.
//! Putting the profile back makes it work again, without signing in to Apple.
//!
//! This doesn't get around the three sideloaded apps a free Apple ID allows: the device counts
//! the apps that are installed, with or without a profile. Tried on iOS 27, where installing a
//! fourth app failed while one of the three had no profile.

use crate::device::{self, Link};
use crate::io;
use anyhow::{Context, Result, anyhow, bail};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// A profile as installed on a device.
pub struct Profile {
    uuid: String,
    /// The bundle ID the profile is for, without the team in front. `*` covers every app.
    app_id: String,
    expires: Option<SystemTime>,
    data: Vec<u8>,
}

impl Profile {
    /// A profile is a signed blob with an XML property list inside.
    fn parse(data: Vec<u8>) -> Option<Profile> {
        let start = data.windows(5).position(|w| w == b"<?xml")?;
        let end = data.windows(8).rposition(|w| w == b"</plist>")? + 8;
        let plist: plist::Dictionary = plist::from_bytes(data.get(start..end)?).ok()?;
        let identifier = plist
            .get("Entitlements")?
            .as_dictionary()?
            .get("application-identifier")?
            .as_string()?;
        // "TEAMID.com.example.app": everything after the team.
        let app_id = identifier.split_once('.')?.1.to_string();
        Some(Profile {
            uuid: plist.get("UUID")?.as_string()?.to_string(),
            app_id,
            expires: plist
                .get("ExpirationDate")
                .and_then(|v| v.as_date())
                .map(SystemTime::from),
            data,
        })
    }

    /// Whether this is the profile of the app with this bundle ID, or of one of its extensions.
    fn belongs_to(&self, bundle_id: &str) -> bool {
        self.app_id == bundle_id || self.app_id.starts_with(&format!("{bundle_id}."))
    }

    /// Whether this profile lets the app with this bundle ID run.
    pub fn covers(&self, bundle_id: &str) -> bool {
        self.app_id == bundle_id || self.app_id == "*"
    }
}

/// Whether a profile, as a file, can still be used. A profile that can't be read can't.
pub fn is_valid(data: &[u8]) -> bool {
    Profile::parse(data.to_vec())
        .and_then(|profile| profile.expires)
        .is_some_and(|expires| expires > SystemTime::now())
}

pub async fn installed(link: &mut Link) -> Result<Vec<Profile>> {
    let mut client = link
        .misagent()
        .await
        .map_err(|e| anyhow!("Can't read the profiles on your device: {e}"))?;
    let profiles = client
        .copy_all()
        .await
        .map_err(|e| anyhow!("Can't read the profiles on your device: {e}"))?;
    Ok(profiles.into_iter().filter_map(Profile::parse).collect())
}

fn saved_profile(folder: &str, bundle_id: &str) -> PathBuf {
    Path::new(folder).join(format!("{bundle_id}.mobileprovision"))
}

/// Takes an app's profile off the device and keeps it in `folder`, to put back later.
pub async fn deactivate(udid: &str, bundle_id: &str, folder: &str) -> Result<()> {
    let mut link = device::link_for(Some(udid)).await?;
    deactivate_on(&mut link, bundle_id, folder).await?;
    io::emit(json!({ "event": "deactivated", "bundle_id": bundle_id }));
    Ok(())
}

async fn deactivate_on(link: &mut Link, bundle_id: &str, folder: &str) -> Result<()> {
    let profiles: Vec<Profile> = installed(link)
        .await?
        .into_iter()
        .filter(|profile| profile.belongs_to(bundle_id))
        .collect();
    let Some(main) = profiles.iter().find(|profile| profile.app_id == bundle_id) else {
        bail!("This app has no profile on your device, so there's nothing to deactivate.");
    };

    std::fs::create_dir_all(folder)?;
    std::fs::write(saved_profile(folder, bundle_id), &main.data)
        .context("Couldn't keep the app's profile")?;

    let mut client = link
        .misagent()
        .await
        .map_err(|e| anyhow!("Can't reach your device: {e}"))?;
    for profile in &profiles {
        client
            .remove(&profile.uuid)
            .await
            .map_err(|e| anyhow!("Couldn't remove the app's profile: {e}"))?;
    }
    Ok(())
}

/// Puts back the profile that `deactivate` kept. Fails when there is none or it has expired;
/// refreshing the app then gives it a new one.
pub async fn activate(udid: &str, bundle_id: &str, folder: &str) -> Result<()> {
    let mut link = device::link_for(Some(udid)).await?;
    activate_on(&mut link, bundle_id, folder).await?;
    io::emit(json!({ "event": "activated", "bundle_id": bundle_id }));
    Ok(())
}

async fn activate_on(link: &mut Link, bundle_id: &str, folder: &str) -> Result<()> {
    let path = saved_profile(folder, bundle_id);
    let data = std::fs::read(&path).map_err(|_| {
        anyhow!("Nimbus has no profile for this app anymore. Refresh the app to activate it.")
    })?;
    let profile = Profile::parse(data)
        .ok_or_else(|| anyhow!("The app's profile is damaged. Refresh the app to activate it."))?;
    if profile
        .expires
        .is_some_and(|expires| expires < SystemTime::now())
    {
        bail!("The app's profile has expired. Refresh the app to activate it.");
    }

    let mut client = link
        .misagent()
        .await
        .map_err(|e| anyhow!("Can't reach your device: {e}"))?;
    client.install(profile.data).await.map_err(|e| {
        anyhow!("Your device didn't take the profile back. Is an app slot free? ({e})")
    })?;
    let _ = std::fs::remove_file(path);
    Ok(())
}

/// Opens an app, activating it first when it's deactivated.
pub async fn wake(udid: &str, bundle_id: &str, folder: &str) -> Result<()> {
    let mut link = device::link_for(Some(udid)).await?;
    let awake = installed(&mut link)
        .await?
        .iter()
        .any(|profile| profile.covers(bundle_id));
    if !awake {
        activate_on(&mut link, bundle_id, folder).await?;
    }
    let mut tunnel = link.into_tunnel(udid).await?;
    tunnel.launch(bundle_id, false).await?;
    io::emit(json!({ "event": "woken", "bundle_id": bundle_id }));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(app_id: &str) -> Profile {
        let data = format!(
            "junk<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>\
             <key>UUID</key><string>ABC-123</string>\
             <key>ExpirationDate</key><date>2030-01-01T00:00:00Z</date>\
             <key>Entitlements</key><dict><key>application-identifier</key>\
             <string>TEAM123456.{app_id}</string></dict></dict></plist>junk"
        );
        Profile::parse(data.into_bytes()).unwrap()
    }

    #[test]
    fn profiles_are_read_out_of_their_wrapping() {
        let profile = profile("com.example.app.TEAM123456");
        assert_eq!(profile.uuid, "ABC-123");
        assert_eq!(profile.app_id, "com.example.app.TEAM123456");
        assert!(profile.expires.unwrap() > SystemTime::now());
        assert!(Profile::parse(b"not a profile".to_vec()).is_none());
    }

    #[test]
    fn profiles_are_matched_to_their_app() {
        let app = profile("com.example.app");
        assert!(app.covers("com.example.app") && app.belongs_to("com.example.app"));
        assert!(!app.covers("com.example.apple") && !app.belongs_to("com.example.apple"));

        let extension = profile("com.example.app.widget");
        assert!(extension.belongs_to("com.example.app") && !extension.covers("com.example.app"));

        let wildcard = profile("*");
        assert!(wildcard.covers("anything") && !wildcard.belongs_to("anything"));
    }
}
