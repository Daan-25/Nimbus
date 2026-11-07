//! The identity Nimbus reports to Apple.
//!
//! Public anisette servers report a Mac on macOS 10.12.6. Apple rejects that for accounts with
//! Advanced Data Protection (which needs macOS 13.1 or later) and, more and more, for every account.
//! So Nimbus reports the Mac it runs on, the same way akd on that Mac would.

use isideload::anisette::AnisetteClientInfo;
use std::process::Command;

// Used when the current Mac's details can't be read.
const FALLBACK_CLIENT_INFO: &str =
    "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
const FALLBACK_USER_AGENT: &str = "akd/1.0 CFNetwork/811.5.4";

pub fn current_mac() -> AnisetteClientInfo {
    let model = run("sysctl", &["-n", "hw.model"]);
    let version = run("sw_vers", &["-productVersion"]);
    let build = run("sw_vers", &["-buildVersion"]);
    let cfnetwork = run(
        "plutil",
        &[
            "-extract",
            "CFBundleVersion",
            "raw",
            "/System/Library/Frameworks/CFNetwork.framework/Resources/Info.plist",
        ],
    );
    let darwin = run("uname", &["-r"]);

    match (model, version, build, cfnetwork, darwin) {
        (Some(model), Some(version), Some(build), Some(cfnetwork), Some(darwin)) => {
            AnisetteClientInfo {
                client_info: format!(
                    "<{model}> <macOS;{version};{build}> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
                ),
                user_agent: format!("akd/1.0 CFNetwork/{cfnetwork} Darwin/{darwin}"),
            }
        }
        _ => AnisetteClientInfo {
            client_info: FALLBACK_CLIENT_INFO.to_string(),
            user_agent: FALLBACK_USER_AGENT.to_string(),
        },
    }
}

fn run(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?.trim().to_string();
    (!text.is_empty()).then_some(text)
}
