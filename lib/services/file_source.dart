import '../models/file_entry.dart';
import 'platform_bridge.dart';

/// Remote Android storage via the active transport (MTP or wireless FTP),
/// routed through [PlatformBridge.listDirectory]. The app browses only the
/// device; the Mac side is Finder, reached through drag & drop.
class RemoteSource {
  final PlatformBridge bridge;
  final String serial;
  final String deviceName;

  /// Where browsing starts. Both transports expose a POSIX tree rooted at "/".
  final String initialPath;

  RemoteSource({
    required this.bridge,
    required this.serial,
    required this.deviceName,
    this.initialPath = '/',
  });

  String get rootLabel => deviceName;

  Future<List<FileEntry>> list(String path) =>
      bridge.listDirectory(serial, path);

  String parentOf(String path) => posixParent(path);

  String join(String path, String name) =>
      path == '/' ? '/$name' : '$path/$name';
}

// --- shared POSIX path helpers (Android paths are always POSIX) ---

String posixParent(String path) {
  if (path == '/' || path.isEmpty) return '/';
  final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final idx = trimmed.lastIndexOf('/');
  if (idx <= 0) return '/';
  return trimmed.substring(0, idx);
}

String posixBasename(String path) {
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final idx = trimmed.lastIndexOf('/');
  return idx < 0 ? trimmed : trimmed.substring(idx + 1);
}
