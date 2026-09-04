# AFT Wi-Fi FTP (Android companion)

A tiny, native (Kotlin) Android app that runs an **FTP server** on the phone so
the macOS **Android File Transfer** app can browse and transfer files over Wi-Fi
— no ADB, no cable, no cloud.

The macOS app is the FTP *client*; this app is the *server* it connects to. It
implements the FTP protocol directly (no third-party FTP library) and serves the
phone's shared storage.

## How it fits together

```
┌─────────────────────────┐        Wi-Fi (same LAN)        ┌──────────────────────────┐
│  macOS app              │  ───────  FTP client  ───────▶ │  This app (FTP server)   │
│  lib/services/          │        passive mode, TYPE I    │  foreground service      │
│  wireless_service.dart  │  ◀──────  data conn  ────────  │  rooted at /sdcard       │
└─────────────────────────┘                                └──────────────────────────┘
```

## Use it

1. Build/install this app (open `android/` in Android Studio, Run), or
   `./gradlew installDebug` once a Gradle wrapper jar is present.
2. Open the app, tap **Grant all-files access**, and allow it (needed to read
   your storage on Android 11+).
3. Tap **Start server**. The app shows an address like `ftp://192.168.1.5:2121`.
4. In the macOS app, open **Connect over Wi-Fi** and enter that IP + port.
   - Default **port** `2121`, **username** `anonymous`, **password** blank —
     these match what the Mac app pre-fills.
5. The phone now appears in the Mac app's device list. Browse and drag files.

Both devices must be on the same Wi-Fi network, and the app must stay running
(it runs as a foreground service, so it keeps going with the screen off).

## What the server implements

Enough of RFC 959 / RFC 3659 for the macOS client, in **passive mode**:

- Auth: `USER` / `PASS` (anonymous by default; set a user/password to lock it down)
- Listing: `MLSD` (primary) and `LIST` (fallback), plus `NLST`
- Navigation: `CWD`, `CDUP`, `PWD`
- Transfers: `RETR`, `STOR`, `APPE`, `REST` (resume), binary `TYPE I`
- Files: `SIZE`, `MDTM`, `DELE`, `MKD`, `RMD`, `RNFR`/`RNTO`
- Data channel: `PASV`, `EPSV`, `PORT`, `EPRT`
- Misc: `FEAT`, `OPTS UTF8`, `SYST`, `NOOP`, `QUIT`

All paths are confined to the served root (no traversal above it).

## Layout

```
android/
├── app/src/main/java/com/aft/ftpserver/
│   ├── MainActivity.kt        # UI: address, start/stop, permissions, log
│   ├── FtpServerService.kt    # foreground service + wake/Wi-Fi locks
│   ├── FtpServer.kt           # accept loop, connection-per-thread
│   ├── FtpSession.kt          # the FTP command/response engine
│   ├── ServerConfig.kt        # port/user/pass/root
│   ├── ServerBus.kt           # state + activity-log event bus
│   └── NetworkUtils.kt        # local Wi-Fi IPv4 discovery
└── app/src/main/res/…         # layout, strings, theme, icons
```

## Security note

FTP is cleartext and intended for use on your **own trusted Wi-Fi**. Prefer
setting a username/password over anonymous, and stop the server when you're done.
