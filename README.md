# Android File Transfer for macOS

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2012%2B-lightgrey)
![Built with Flutter](https://img.shields.io/badge/built%20with-Flutter-02569B?logo=flutter&logoColor=white)
![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)

A fast, no-nonsense macOS app for moving files between your Mac and an Android
phone — **over USB or Wi‑Fi, with no ADB and no cloud account.** Browse your
phone's storage in a native window and drag files straight to and from Finder.

> Tired of Google's long-abandoned "Android File Transfer" and sketchy cloud
> uploaders? This is a local-only, open-source alternative that just works.

<!-- 📸 Add a screenshot at docs/screenshot.png and uncomment the line below —
     it dramatically improves first impressions on GitHub and LinkedIn. -->
<!-- ![Screenshot](docs/screenshot.png) -->

## ✨ Highlights

- **Two ways to connect, no setup headaches**
  - **USB (MTP):** plug in, set the phone to *File Transfer / MTP* — no
    Developer Options, no ADB, no drivers.
  - **Wi‑Fi (FTP):** run the bundled **[Android companion app](android/)**
    (or any FTP‑server app) on the phone and connect over your LAN — no cable, no
    ADB. FTP is used deliberately: it's the most widely supported phone-side
    protocol *and* the fastest for bulk transfer (a raw binary data channel with
    almost no overhead).
- **Finder drag & drop**, both directions.
- **Transfer queue** with live progress, speed, cancel, and Queue/Parallel modes.
- **Manage the phone**: browse, sort, delete, make folders, recursive folder upload.
- **100% local** — no accounts, no cloud, no telemetry.

## 📋 Requirements

- macOS 12 (Monterey) or later
- [Flutter](https://docs.flutter.dev/get-started/install/macos) 3.x (Dart 3.11+)
- **For USB/MTP:** `brew install libmtp`
- **For Wi‑Fi:** the bundled [`android/`](android/) companion
  app (build in Android Studio), or any FTP‑server app on the phone
  (e.g. *WiFi FTP Server*, *primitive ftpd*)

## 🚀 Build & run

```bash
git clone https://github.com/<your-username>/android-file-transfer-macos.git
cd android-file-transfer-macos
brew install libmtp          # required for the USB/MTP transport
flutter pub get
flutter run -d macos         # or: flutter build macos --debug
```

The app is built unsigned for personal use — macOS may ask you to confirm the
first launch (right‑click → Open).

## 📖 Usage

### USB (MTP)
1. Connect the phone via USB.
2. On the phone, choose USB mode **File Transfer / MTP**.
3. Keep the transport toggle on **MTP** — your phone appears in the device list.

### Wi‑Fi (FTP)
1. On the phone, install and start an FTP‑server app and note the `IP:port` it
   shows. The easiest option is the bundled **[AFT Wi‑Fi FTP](android/)**
   companion app — tap *Grant all-files access*, then *Start server*; its
   defaults (port `2121`, user `anonymous`, no password) already match the Mac.
2. Make sure the Mac and phone are on the **same network**.
3. Click the **Wi‑Fi** button, enter the address (plus username/password if the
   app requires one), and **Connect**.

Then browse the phone and drag files to/from Finder.

> **Ships with a companion server:** this repo includes a small native-Kotlin
> Android FTP server in [`android/`](android/) so you don't
> need a third-party app. See its [README](android/README.md) for
> build and usage details.

## 🏗️ How it works

The UI is transport-agnostic: everything above the transport layer talks to a
single `PlatformBridge` façade that routes each browse/transfer call to the
active transport and merges both sides' events into one stream.

| Layer | Tech |
| --- | --- |
| UI + state | Flutter, `flutter_bloc` (Cubits) |
| Router / façade | `lib/services/platform_bridge.dart` |
| USB (MTP) transport | Native Swift + `libmtp` (`macos/Runner/Mtp*.swift`, `MtpBridge.m`) |
| Wi‑Fi (FTP) transport | Pure Dart, [`ftpconnect`](https://pub.dev/packages/ftpconnect) (`lib/services/wireless_service.dart`) |
| Phone-side FTP server | Native Kotlin, hand-written FTP engine ([`android/`](android/)) |
| Mac ↔ app channel | `MethodChannel`/`EventChannel` `app.filebridge/*` |

Both transports implement the same command contract
(`listDirectory` / `pushFile` / `pullFile` / `deleteRemote` / `makeRemoteDir` /
`remoteFreeSpace`) and emit identical `transferProgress` / `transferDone` /
`devicesChanged` events, so the browser and transfer queue never need to know
which one is live.

## 🤝 Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md). Open an issue to discuss larger changes
before starting.

## 📜 License

Licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE).
In short: you're free to use, study, share, and modify this software, but
distributed derivatives must remain open source under the same license.

## ⚠️ Disclaimer

A personal, local-first project. Built unsigned / un-notarized — you run it from
source. Not affiliated with, endorsed by, or sponsored by Google. "Android" is a
trademark of Google LLC.
