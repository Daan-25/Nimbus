# Nimbus

Nimbus installs apps on your iPhone or iPad with a free Apple ID: no jailbreak, no paid developer account.
It's an alternative to AltStore and SideStore, built to remove the parts that get in the way.

> **Status:** early. The Mac app installs apps from AltStore sources or `.ipa` files and refreshes them. See the [roadmap](#roadmap).

## Why Nimbus

- **Works with Advanced Data Protection.** Other tools sign in as a Mac running macOS 10.12.6. Apple needs
  macOS 13.1 or later for accounts with ADP turned on, so the verification code never arrives. Nimbus signs in
  as the Mac it's running on, so the code arrives and sign-in works.
- **Respects Apple's rate limit.** After an HTTP 429, other tools often retry straight away, which only
  extends Apple's block. Nimbus doesn't retry. It tells you when it's sensible to try again.
- **Refreshes in the background.** Nimbus lives in the menu bar and refreshes your apps two days before they
  expire, over a cable or Wi-Fi. It refreshes all apps with one sign-in, and never more than once every six hours.
- **Shows your limits.** See how many of your 3 app slots are used and how many app IDs you have left this week,
  and remove apps from your device to free a slot.
- **Works with AltStore sources.** Add a source, then install and update its apps from Nimbus. Downloads are
  checked against the source's checksum when it has one.
- **No separate server.** No AltServer and no mail plug-in. One app does everything.
- **Clear errors.** Common problems come with a plain explanation of what to do.
- **Your password stays on your Mac.** It goes only to Apple, and the Keychain stores it only if you ask.

## Requirements

- macOS 14 or later
- An iPhone or iPad connected with a cable, unlocked, with this Mac trusted
- Developer Mode turned on (Settings → Privacy & Security), which iOS asks for after the first install

## Build

You need Xcode (or the Command Line Tools) and [Rust](https://rustup.rs).

```sh
./scripts/build.sh
open build/Nimbus.app
```

The iPhone app installs `.ipa` files and refreshes your apps without the Mac. To build it, add the Rust
targets once with `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`. `build.sh` then puts the
iPhone app inside the Mac app, which offers to install it. To build it on its own:

```sh
./scripts/build-ios.sh        # build/Nimbus-iOS.ipa, unsigned: install it with Nimbus on your Mac
./scripts/build-ios.sh sim    # build/ios-simulator/Nimbus.app, for the iOS Simulator
```

## How it works

| Part | What it does |
| --- | --- |
| `mac/` | SwiftUI app for the Mac |
| `ios/` | SwiftUI app for iPhone and iPad |
| `shared/` | Swift code both apps use |
| `core/` | The engine, in Rust: signs in to Apple, signs the app and installs it. Built on [isideload](https://github.com/nab138/isideload) and [idevice](https://github.com/jkcoxson/idevice). |

Both apps exchange JSON messages with the engine. The Mac app runs it as a separate tool, `nimbus-helper`,
over stdin and stdout. The iPhone app links it and calls the C functions in `core/include/nimbus_core.h`.
Run `nimbus-helper client-info` to see what Nimbus reports to Apple.

An iPhone app can't talk to its own device directly, so on the iPhone the engine connects through a
loopback VPN (LocalDevVPN, from the App Store). It proves who it is with a remote pairing file and opens an
encrypted tunnel to the device; since iOS 26.4, devices hang up on the older lockdown connection when it
comes from themselves. The Mac app creates the pairing file when it installs the iPhone app, and puts it in
the app's Documents folder together with the Mac's identity, its signing key for your Apple ID and a copy of
the apps it installed on that device. With the same key and identity, the iPhone signs with the Mac's
certificate and Apple sees one machine; a free Apple ID has too few certificates for each to have its own.
The iPhone app moves the keys out of Documents the first time it opens.

Both refresh apps two days before they expire. The iPhone app does it when you open it and, when iOS
gives it time, in the background; it needs LocalDevVPN on and warns you a day ahead if it couldn't. It
records what it refreshed in `refreshed.json`, which the Mac reads so it doesn't sign in for the same apps.

Apps the iPhone installs itself, from an `.ipa` you pick or open with Nimbus, are kept in a list of their
own, apart from the one the Mac copies over. The Mac shows them as installed with another tool.

To try that connection from the Mac, over Wi-Fi:

```sh
nimbus-helper pairing-file UDID pairing.plist
NIMBUS_DEVICE_ADDRESS=<device IP> NIMBUS_PAIRING_FILE=pairing.plist nimbus-helper diagnose
```

Nimbus keeps a copy of every app you install in `~/Library/Application Support/Nimbus`, so it can refresh
them later. The sources you added are cached in `sources.json` in the same folder.

Nimbus only loads sources and downloads over HTTPS. It leaves out apps for Patreon supporters, because
downloading those needs a Patreon sign-in.

## Roadmap

- [x] Mac app: sign in (with ADP), install an `.ipa`
- [x] Track installed apps and refresh them before they expire after 7 days
- [x] Show limits: 3 apps and 10 app IDs a week on a free account
- [x] Refresh over Wi-Fi
- [x] AltStore sources: browse, install and update apps
- [ ] iOS app: refresh without a Mac, and enable JIT
  - [x] The engine builds for iOS and connects through a remote pairing tunnel
  - [x] First iPhone app: shows the sideloaded apps on the device
  - [x] The Mac app installs the iPhone app and sets it up
  - [x] Sign in and refresh on the iPhone
  - [ ] Refresh in the background on the iPhone (built; iOS decides when it runs, so not yet seen working)
  - [x] Install `.ipa` files on the iPhone and remove apps there
  - [ ] Install from sources on the iPhone, and enable JIT

## Credits

- [isideload](https://github.com/nab138/isideload) by nab138: sign-in, signing and installation
- [idevice](https://github.com/jkcoxson/idevice) by jkcoxson: communication with iOS devices
- [AltStore](https://github.com/altstoreio/AltStore) and [SideStore](https://github.com/SideStore/SideStore), which made all of this possible

## License

[MIT](LICENSE)
