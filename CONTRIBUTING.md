# Contributing

Thanks for your interest in improving **Android File Transfer for macOS**!
Contributions of all kinds are welcome — bug reports, fixes, features, and docs.

## Getting set up

```bash
brew install libmtp          # required for the USB/MTP transport
flutter pub get
flutter run -d macos
```

You'll need:
- macOS 12+ and Xcode (for the native macOS build)
- Flutter 3.x (Dart 3.11+)
- An Android phone for manual testing — MTP over USB, or an FTP‑server app for Wi‑Fi

## Before you open a PR

Please make sure:

```bash
flutter analyze          # must report "No issues found"
flutter build macos --debug   # must build cleanly
```

- Keep changes focused; open an issue first for anything large or architectural.
- **Match the surrounding style.** The code favours small, well-commented units
  and explains *why*, not *what*. Read a neighbouring file before adding one.
- Both transports share one command contract — if you touch the transport layer,
  keep MTP (`macos/Runner/Mtp*`) and Wireless (`lib/services/wireless_service.dart`)
  emitting the same `transferProgress` / `transferDone` / `devicesChanged` shapes.
- This is a personal-scale project; there is no large automated test suite. Verify
  your change by actually running the affected flow and say so in the PR.

## Commit & PR

- Write clear commit messages (imperative mood: "Add…", "Fix…").
- Describe what you changed and how you tested it in the PR body.
- Link the issue it closes (`Closes #123`).

## Reporting bugs

Open an issue using the Bug report template. Include your macOS version, the
transport (MTP or Wi‑Fi), the phone model/Android version, and the exact steps.

By contributing, you agree that your contributions are licensed under the
project's [GPL‑3.0 license](LICENSE).
