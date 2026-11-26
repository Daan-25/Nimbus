//! The identity Nimbus reports to Apple.
//!
//! Public anisette servers report a Mac on macOS 10.12.6. Apple rejects that for accounts with
//! Advanced Data Protection (which needs macOS 13.1 or later) and, more and more, for every account.
//! So Nimbus reports the Mac it runs on, the same way akd on that Mac would.
//!
//! Since 20 November 2026, Apple's sign-in server answers 503 when the client info names the
//! system "macOS"; "Mac OS X", as older Macs called it, still works. So Nimbus says that.

use crate::config;
use isideload::anisette::AnisetteClientInfo;

// Used when the Mac's details aren't known.
const FALLBACK_CLIENT_INFO: &str =
    "<Mac15,7> <Mac OS X;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
const FALLBACK_USER_AGENT: &str = "akd/1.0 CFNetwork/811.5.4";

/// The identity to sign in with: the one the app passed in, or else this Mac's.
pub fn current() -> AnisetteClientInfo {
    let config = config::get();
    let info = if let (Some(client_info), Some(user_agent)) = (config.client_info, config.user_agent) {
        AnisetteClientInfo {
            client_info,
            user_agent,
        }
    } else {
        current_mac()
    };
    // Also for an identity saved before Apple started refusing "macOS", such as the one the
    // Mac gave Nimbus on the iPhone.
    AnisetteClientInfo {
        client_info: info.client_info.replace("<macOS;", "<Mac OS X;"),
        user_agent: info.user_agent,
    }
}

#[cfg(not(target_os = "macos"))]
fn current_mac() -> AnisetteClientInfo {
    AnisetteClientInfo {
        client_info: FALLBACK_CLIENT_INFO.to_string(),
        user_agent: FALLBACK_USER_AGENT.to_string(),
    }
}

#[cfg(target_os = "macos")]
fn current_mac() -> AnisetteClientInfo {
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
                    "<{model}> <Mac OS X;{version};{build}> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
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

#[cfg(target_os = "macos")]
fn run(program: &str, args: &[&str]) -> Option<String> {
    let output = std::process::Command::new(program)
        .args(args)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?.trim().to_string();
    (!text.is_empty()).then_some(text)
}
