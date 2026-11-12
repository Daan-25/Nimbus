//! Where the engine keeps what it needs between sign-ins: the signing key and anisette state.
//!
//! On a Mac that's the Keychain. Inside the iPhone app it's a folder the app chooses, so the
//! Mac can hand over its signing key; with the same key both sign with one certificate
//! instead of revoking each other's.

use crate::config;
use isideload::util::{keyring_storage::KeyringStorage, storage::SideloadingStorage};
use rootcause::Report;
use std::path::PathBuf;

const KEYCHAIN_SERVICE: &str = "Nimbus";
/// Under this key isideload keeps the state that identifies this machine to Apple.
#[cfg(target_os = "macos")]
pub const ANISETTE_STATE_KEY: &str = "anisette_state";

pub fn new() -> Box<dyn SideloadingStorage> {
    match config::get().storage_dir {
        Some(folder) => Box::new(FileStorage { folder }),
        None => Box::new(KeyringStorage::new(KEYCHAIN_SERVICE.to_string())),
    }
}

/// Under this key isideload keeps the private key of an Apple ID's signing certificate.
#[cfg(target_os = "macos")]
pub fn signing_key_name(apple_id: &str) -> String {
    use sha2::{Digest, Sha256};
    let hash = Sha256::digest(apple_id.trim().to_lowercase().as_bytes());
    format!("{}/key", hex::encode(hash))
}

/// One file per key.
struct FileStorage {
    folder: PathBuf,
}

impl SideloadingStorage for FileStorage {
    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        let path = self.folder.join(key);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, value)?;
        Ok(())
    }

    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        match std::fs::read_to_string(self.folder.join(key)) {
            Ok(value) if value.is_empty() => Ok(None),
            Ok(value) => Ok(Some(value)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    fn delete(&self, key: &str) -> Result<(), Report> {
        match std::fs::remove_file(self.folder.join(key)) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
            _ => Ok(()),
        }
    }
}
