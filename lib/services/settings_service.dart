import 'dart:convert';
import 'dart:io';

/// Tiny JSON-file preferences store in Application Support (no accounts, no
/// server, per spec). Currently just remembers the last-visited device path.
class SettingsService {
  File get _file {
    final home = Platform.environment['HOME'] ?? '';
    final dir = Directory('$home/Library/Application Support/FileBridge');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}/prefs.json');
  }

  Map<String, dynamic> _read() {
    try {
      final f = _file;
      if (f.existsSync()) {
        return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  void _write(Map<String, dynamic> map) {
    try {
      _file.writeAsStringSync(jsonEncode(map));
    } catch (_) {}
  }

  /// Last-visited directory, keyed by transport — MTP and wireless (FTP) expose
  /// different trees, so their remembered paths must not cross-contaminate.
  String? lastRemotePathFor(String transport) =>
      _read()['lastRemotePath_$transport'] as String?;

  void setLastRemotePath(String transport, String? path) {
    final map = _read();
    map['lastRemotePath_$transport'] = path;
    _write(map);
  }
}
