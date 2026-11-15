//! Tweaks: dynamic libraries added to an app, which iOS loads when the app starts.
//!
//! Nimbus copies each tweak into the app's Frameworks folder and adds it to the app's main
//! program as a weak dependency, before signing. The original .ipa stays as it was, so taking a
//! tweak off is a matter of refreshing without it.
//!
//! A device without a jailbreak has no tweak loader such as Substrate, so a tweak can only rely
//! on what iOS itself provides. Tweaks that need more are refused here, before they could stop
//! the app from starting.

use anyhow::{Context, Result, anyhow, bail};
use std::path::{Path, PathBuf};

const MH_MAGIC_64: u32 = 0xFEED_FACF;
const FAT_MAGIC: u32 = 0xCAFE_BABE;
const FAT_MAGIC_64: u32 = 0xCAFE_BABF;
const CPU_TYPE_ARM64: i32 = 0x0100_000C;
const MH_DYLIB: u32 = 6;
const LC_SEGMENT_64: u32 = 0x19;
const LC_ID_DYLIB: u32 = 0x0D;
const LC_LOAD_DYLIB: u32 = 0x0C;
const LC_LOAD_WEAK_DYLIB: u32 = 0x8000_0018;
const LC_REEXPORT_DYLIB: u32 = 0x8000_001F;
const LC_LOAD_UPWARD_DYLIB: u32 = 0x8000_0023;
const LC_ENCRYPTION_INFO_64: u32 = 0x2C;

/// Where a tweak may find what it links against: iOS itself, or the app it's added to.
const ALLOWED_PREFIXES: [&str; 5] = [
    "/System/",
    "/usr/lib/",
    "@executable_path/",
    "@loader_path/",
    "@rpath/",
];

fn u32_le(data: &[u8], at: usize) -> Result<u32> {
    Ok(u32::from_le_bytes(
        data.get(at..at + 4)
            .ok_or_else(|| anyhow!("Truncated program"))?
            .try_into()?,
    ))
}

fn u32_be(data: &[u8], at: usize) -> Result<u32> {
    Ok(u32::from_be_bytes(
        data.get(at..at + 4)
            .ok_or_else(|| anyhow!("Truncated program"))?
            .try_into()?,
    ))
}

/// The arm64 programs in a file: (offset, size) of each, one for a thin file.
fn arm64_slices(data: &[u8]) -> Result<Vec<(usize, usize)>> {
    match u32_be(data, 0)? {
        FAT_MAGIC | FAT_MAGIC_64 => {
            let wide = u32_be(data, 0)? == FAT_MAGIC_64;
            let count = u32_be(data, 4)? as usize;
            let entry = if wide { 32 } else { 20 };
            let mut slices = Vec::new();
            for index in 0..count {
                let at = 8 + index * entry;
                let cpu = u32_be(data, at)? as i32;
                let (offset, size) = if wide {
                    let offset = u64::from_be_bytes(data[at + 8..at + 16].try_into()?) as usize;
                    let size = u64::from_be_bytes(data[at + 16..at + 24].try_into()?) as usize;
                    (offset, size)
                } else {
                    (
                        u32_be(data, at + 8)? as usize,
                        u32_be(data, at + 12)? as usize,
                    )
                };
                if cpu == CPU_TYPE_ARM64 {
                    slices.push((offset, size));
                }
            }
            Ok(slices)
        }
        _ if u32_le(data, 0)? == MH_MAGIC_64 => {
            let cpu = u32_le(data, 4)? as i32;
            Ok(if cpu == CPU_TYPE_ARM64 {
                vec![(0, data.len())]
            } else {
                vec![]
            })
        }
        _ => bail!("This isn't a program for iOS."),
    }
}

struct Command {
    kind: u32,
    offset: usize,
    size: usize,
}

/// The load commands of one 64-bit slice, and where they end.
fn commands(slice: &[u8]) -> Result<(Vec<Command>, usize)> {
    if u32_le(slice, 0)? != MH_MAGIC_64 {
        bail!("This isn't a 64-bit program.");
    }
    let count = u32_le(slice, 16)? as usize;
    let mut offset = 32;
    let mut list = Vec::with_capacity(count);
    for _ in 0..count {
        let kind = u32_le(slice, offset)?;
        let size = u32_le(slice, offset + 4)? as usize;
        if size < 8 {
            bail!("The program's load commands are damaged.");
        }
        list.push(Command { kind, offset, size });
        offset += size;
    }
    Ok((list, offset))
}

fn dylib_name(slice: &[u8], command: &Command) -> Option<String> {
    let name_offset = u32_le(slice, command.offset + 8).ok()? as usize;
    let bytes = slice.get(command.offset + name_offset..command.offset + command.size)?;
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    Some(String::from_utf8_lossy(&bytes[..end]).into_owned())
}

/// Checks that a file is a tweak that can work on a device without a jailbreak, and returns
/// what it says it is (its install name), for showing.
pub fn check(path: &Path) -> Result<String> {
    let data = std::fs::read(path).with_context(|| format!("Can't read {}", path.display()))?;
    let slices = arm64_slices(&data)?;
    let (offset, size) = *slices
        .first()
        .ok_or_else(|| anyhow!("This tweak isn't built for iPhone or iPad (arm64)."))?;
    let slice = &data[offset..offset + size];
    if u32_le(slice, 12)? != MH_DYLIB {
        bail!("This isn't a tweak (.dylib), but another kind of program.");
    }
    let (list, _) = commands(slice)?;
    let mut id = String::new();
    for command in &list {
        match command.kind {
            LC_ID_DYLIB => id = dylib_name(slice, command).unwrap_or_default(),
            LC_LOAD_DYLIB | LC_REEXPORT_DYLIB | LC_LOAD_UPWARD_DYLIB => {
                let name = dylib_name(slice, command).unwrap_or_default();
                if !ALLOWED_PREFIXES
                    .iter()
                    .any(|prefix| name.starts_with(prefix))
                {
                    bail!(
                        "This tweak needs {name}, which an iPhone without a jailbreak doesn't have. \
                         Tweaks made for jailbroken devices usually need Substrate or ElleKit."
                    );
                }
            }
            _ => {}
        }
    }
    Ok(id)
}

/// Adds a weak dependency on `name` to every arm64 slice of a program, in the free space after
/// its load commands. Does nothing when it's there already.
fn add_weak_dependency(program: &Path, name: &str) -> Result<()> {
    let mut data = std::fs::read(program)?;
    for (offset, size) in arm64_slices(&data)? {
        let slice = &mut data[offset..offset + size];
        let (list, end) = commands(slice)?;
        if list.iter().any(|command| {
            matches!(command.kind, LC_LOAD_DYLIB | LC_LOAD_WEAK_DYLIB)
                && dylib_name(slice, command).as_deref() == Some(name)
        }) {
            continue;
        }
        if list.iter().any(|command| {
            command.kind == LC_ENCRYPTION_INFO_64
                && u32_le(slice, command.offset + 16).unwrap_or(0) != 0
        }) {
            bail!("This app is encrypted by the App Store, so it can't run sideloaded at all.");
        }

        // Free space ends where the first section's contents begin.
        let mut first_used = slice.len();
        for command in list.iter().filter(|command| command.kind == LC_SEGMENT_64) {
            let sections = u32_le(slice, command.offset + 64)? as usize;
            for index in 0..sections {
                let section = command.offset + 72 + index * 80;
                let contents = u32_le(slice, section + 48)? as usize;
                if contents != 0 {
                    first_used = first_used.min(contents);
                }
            }
        }

        let mut encoded = name.as_bytes().to_vec();
        encoded.push(0);
        let command_size = (24 + encoded.len()).div_ceil(8) * 8;
        if first_used < end + command_size {
            bail!("The app's main program has no room for another library.");
        }
        if slice[end..end + command_size].iter().any(|byte| *byte != 0) {
            bail!("The app's main program has no free room for another library.");
        }

        let mut command = Vec::with_capacity(command_size);
        for value in [
            LC_LOAD_WEAK_DYLIB,
            command_size as u32,
            24,
            2,
            0x1_0000,
            0x1_0000,
        ] {
            command.extend_from_slice(&value.to_le_bytes());
        }
        command.extend_from_slice(&encoded);
        command.resize(command_size, 0);
        slice[end..end + command_size].copy_from_slice(&command);

        let count = u32_le(slice, 16)? + 1;
        let commands_size = u32_le(slice, 20)? + command_size as u32;
        slice[16..20].copy_from_slice(&count.to_le_bytes());
        slice[20..24].copy_from_slice(&commands_size.to_le_bytes());
    }
    std::fs::write(program, data)?;
    Ok(())
}

/// Adds tweaks to an unpacked app: copies each into its Frameworks folder and makes the main
/// program load it.
pub fn add(app: &Path, tweaks: &[PathBuf]) -> Result<()> {
    let info: plist::Dictionary =
        plist::from_file(app.join("Info.plist")).context("Can't read the app's Info.plist")?;
    let executable = info
        .get("CFBundleExecutable")
        .and_then(|value| value.as_string())
        .ok_or_else(|| anyhow!("The app doesn't name its main program."))?;
    let program = app.join(executable);
    let frameworks = app.join("Frameworks");
    std::fs::create_dir_all(&frameworks)?;

    for tweak in tweaks {
        check(tweak)?;
        let name = tweak
            .file_name()
            .and_then(|name| name.to_str())
            .filter(|name| name.ends_with(".dylib"))
            .ok_or_else(|| anyhow!("A tweak has to be a .dylib file."))?;
        // Nimbus keeps tweaks under names of its own; the app sees them as Nimbus-<name>.
        let target = format!("Nimbus-{name}");
        std::fs::copy(tweak, frameworks.join(&target))
            .with_context(|| format!("Couldn't add {name} to the app"))?;
        add_weak_dependency(&program, &format!("@executable_path/Frameworks/{target}"))?;
    }
    Ok(())
}

/// A tweak that was found but can't be used, and why.
pub struct Refused {
    pub name: String,
    pub reason: String,
}

/// Takes in a tweak to keep beside the apps: a .dylib, or the .dylib files in a .deb package.
/// Each usable one is copied into `folder` as `prefix` + its name. Returns the file names and
/// the ones that were refused; fails when none can be used.
pub fn import(source: &Path, folder: &Path, prefix: &str) -> Result<(Vec<String>, Vec<Refused>)> {
    let extension = source
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or_default()
        .to_lowercase();
    let candidates: Vec<(String, Vec<u8>)> = match extension.as_str() {
        "dylib" => vec![(
            source
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned(),
            std::fs::read(source).with_context(|| format!("Can't read {}", source.display()))?,
        )],
        "deb" => dylibs_in_deb(source)?,
        _ => bail!("A tweak has to be a .dylib file or a .deb package."),
    };
    if candidates.is_empty() {
        bail!("This package has no tweak libraries in it.");
    }

    let scratch = std::env::temp_dir().join(format!("nimbus-tweak-{}", std::process::id()));
    std::fs::create_dir_all(&scratch)?;
    let mut files = Vec::new();
    let mut refused = Vec::new();
    for (name, data) in candidates {
        let checked = scratch.join(&name);
        std::fs::write(&checked, &data)?;
        match check(&checked) {
            Ok(_) => {
                let file = format!("{prefix}{name}");
                std::fs::copy(&checked, folder.join(&file))?;
                files.push(file);
            }
            Err(error) => refused.push(Refused {
                name,
                reason: error.to_string(),
            }),
        }
    }
    let _ = std::fs::remove_dir_all(&scratch);

    if files.is_empty() {
        let reason = refused
            .first()
            .map(|r| r.reason.clone())
            .unwrap_or_else(|| "It has no usable tweak.".to_string());
        bail!("{reason}");
    }
    Ok((files, refused))
}

/// The .dylib files a .deb package installs where tweak loaders look for them, by file name.
fn dylibs_in_deb(path: &Path) -> Result<Vec<(String, Vec<u8>)>> {
    use std::io::Read;

    let file =
        std::fs::File::open(path).with_context(|| format!("Can't read {}", path.display()))?;
    let mut package = ar::Archive::new(file);
    while let Some(entry) = package.next_entry() {
        let mut entry = entry.map_err(|_| anyhow!("This isn't a valid .deb package."))?;
        let name = String::from_utf8_lossy(entry.header().identifier()).into_owned();
        let Some(compression) = name.strip_prefix("data.tar") else {
            continue;
        };
        let mut packed = Vec::new();
        entry.read_to_end(&mut packed)?;
        let unpacked = match compression.trim_end_matches('/') {
            "" => packed,
            ".gz" => {
                let mut out = Vec::new();
                flate2::read::GzDecoder::new(&packed[..]).read_to_end(&mut out)?;
                out
            }
            ".xz" => {
                let mut out = Vec::new();
                lzma_rs::xz_decompress(&mut &packed[..], &mut out)
                    .map_err(|e| anyhow!("Couldn't unpack the package: {e}"))?;
                out
            }
            ".lzma" => {
                let mut out = Vec::new();
                lzma_rs::lzma_decompress(&mut &packed[..], &mut out)
                    .map_err(|e| anyhow!("Couldn't unpack the package: {e}"))?;
                out
            }
            ".zst" => {
                let mut out = Vec::new();
                ruzstd::decoding::StreamingDecoder::new(&packed[..])
                    .map_err(|e| anyhow!("Couldn't unpack the package: {e}"))?
                    .read_to_end(&mut out)?;
                out
            }
            other => bail!("Nimbus can't unpack packages compressed as {other}."),
        };
        return tweak_libraries(&unpacked);
    }
    bail!("This isn't a valid .deb package: it has no contents.")
}

/// The .dylib files in a package's contents that a tweak loader would load: those in a
/// DynamicLibraries or TweakInject folder, rootful or rootless.
fn tweak_libraries(contents: &[u8]) -> Result<Vec<(String, Vec<u8>)>> {
    use std::io::Read;

    let mut found = Vec::new();
    let mut archive = tar::Archive::new(contents);
    for entry in archive.entries()? {
        let mut entry = entry?;
        if !entry.header().entry_type().is_file() {
            continue;
        }
        let path = entry.path()?.to_string_lossy().into_owned();
        let in_tweak_folder = ["MobileSubstrate/DynamicLibraries/", "usr/lib/TweakInject/"]
            .iter()
            .any(|folder| path.contains(folder));
        let Some(name) = path.rsplit('/').next().map(str::to_string) else {
            continue;
        };
        if in_tweak_folder && name.ends_with(".dylib") {
            let mut data = Vec::new();
            entry.read_to_end(&mut data)?;
            found.push((name, data));
        }
    }
    Ok(found)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_programs_are_refused() {
        let folder = std::env::temp_dir().join("nimbus-tweak-test");
        std::fs::create_dir_all(&folder).unwrap();
        let file = folder.join("not-a-tweak.dylib");
        std::fs::write(&file, b"hello").unwrap();
        assert!(check(&file).is_err());
        let _ = std::fs::remove_dir_all(folder);
    }

    /// Needs a real tweak and app: NIMBUS_TEST_TWEAK (a .dylib) and NIMBUS_TEST_APP (an
    /// unpacked .app folder, which this changes).
    #[test]
    fn tweaks_are_added_once() {
        let (Ok(tweak), Ok(app)) = (
            std::env::var("NIMBUS_TEST_TWEAK"),
            std::env::var("NIMBUS_TEST_APP"),
        ) else {
            return;
        };
        let (tweak, app) = (PathBuf::from(tweak), PathBuf::from(app));
        add(&app, std::slice::from_ref(&tweak)).unwrap();
        add(&app, std::slice::from_ref(&tweak)).unwrap();

        let info: plist::Dictionary = plist::from_file(app.join("Info.plist")).unwrap();
        let program = app.join(info["CFBundleExecutable"].as_string().unwrap());
        let data = std::fs::read(program).unwrap();
        let (offset, size) = arm64_slices(&data).unwrap()[0];
        let slice = &data[offset..offset + size];
        let name = format!(
            "@executable_path/Frameworks/Nimbus-{}",
            tweak.file_name().unwrap().to_string_lossy()
        );
        let (list, _) = commands(slice).unwrap();
        let found = list
            .iter()
            .filter(|command| dylib_name(slice, command).as_deref() == Some(name.as_str()))
            .count();
        assert_eq!(found, 1);
    }
}
