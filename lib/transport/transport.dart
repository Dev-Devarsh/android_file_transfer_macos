/// How the app reaches the device. MTP is the USB "File Transfer" mode (no
/// developer options needed); Wireless is FTP over Wi-Fi to a file-server app
/// running on the phone (no ADB, no cable).
enum TransportKind { mtp, wireless }

extension TransportKindX on TransportKind {
  /// Wire value persisted in preferences and understood by the native side.
  String get wire => this == TransportKind.wireless ? 'wireless' : 'mtp';

  String get label => this == TransportKind.wireless ? 'Wireless' : 'MTP';

  /// Where browsing starts. Both transports expose a POSIX tree rooted at "/".
  String get initialPath => '/';

  static TransportKind fromWire(Object? v) =>
      v == 'wireless' ? TransportKind.wireless : TransportKind.mtp;
}
