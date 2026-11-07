# Nimbus

Nimbus installs apps on your iPhone or iPad with a free Apple ID: no jailbreak, no paid developer account.
It's an alternative to AltStore and SideStore, built to remove the parts that get in the way.

> **Status:** early. The Mac app can sign in and install an `.ipa`. See the [roadmap](#roadmap).

## Why Nimbus

- **Works with Advanced Data Protection.** Other tools sign in as a Mac running macOS 10.12.6. Apple needs
  macOS 13.1 or later for accounts with ADP turned on, so the verification code never arrives. Nimbus signs in
  as the Mac it's running on, so the code arrives and sign-in works.
- **Respects Apple's rate limit.** After an HTTP 429, other tools often retry straight away, which only
  extends Apple's block. Nimbus doesn't retry. It tells you when it's sensible to try again.
- **No separate server.** No AltServer menu bar app and no mail plug-in. One app does everything.
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

## How it works

| Part | What it does |
| --- | --- |
| `mac/` | SwiftUI app |
| `core/` | `nimbus-helper`, a Rust binary that signs in to Apple, signs the app and installs it. Built on [isideload](https://github.com/nab138/isideload) and [idevice](https://github.com/jkcoxson/idevice). |

The app and the helper exchange JSON lines over stdin and stdout. Run `nimbus-helper client-info` to see
what Nimbus reports to Apple.

## Roadmap

- [x] Mac app: sign in (with ADP), install an `.ipa`
- [ ] Track installed apps and refresh them before they expire after 7 days
- [ ] Show limits: 3 apps and 10 app IDs a week on a free account
- [ ] Refresh over Wi-Fi
- [ ] iOS app: refresh without a Mac, and enable JIT
- [ ] Support AltStore sources

## Credits

- [isideload](https://github.com/nab138/isideload) by nab138: sign-in, signing and installation
- [idevice](https://github.com/jkcoxson/idevice) by jkcoxson: communication with iOS devices
- [AltStore](https://github.com/altstoreio/AltStore) and [SideStore](https://github.com/SideStore/SideStore), which made all of this possible

## License

[MIT](LICENSE)
