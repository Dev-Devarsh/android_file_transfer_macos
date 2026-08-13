import 'dart:async';
import 'dart:io';

import 'package:ftpconnect/ftpconnect.dart';

import '../models/file_entry.dart';

/// The wireless transport: FTP over Wi-Fi to a file-server app running on the
/// phone (no ADB, no cable). Chosen because FTP is both the most widely
/// supported phone-side server protocol and the fastest for bulk transfer — a
/// raw binary data connection with almost no per-byte overhead.
///
/// This mirrors the method/event contract the native transports expose so the
/// cubits stay transport-agnostic: browse/transfer calls look the same, and
/// progress/completion are pushed as `transferProgress` / `transferDone` maps
/// with identical shapes. Device presence is reported via `devicesChanged`.
///
/// Every operation uses its own short-lived connection (FTP's command channel
/// is single-use), which also lets independent transfers run in parallel. A
/// transfer's connection is tracked by id so [cancel] can abort it.
class WirelessService {
  /// The single synthetic serial the wireless "device" reports. The router
  /// ignores it and uses the stored connection.
  static const wirelessSerial = 'wifi';

  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _active = <String, FTPConnect>{};
  final _cancelled = <String>{};

  _WifiConfig? _config;

  Stream<Map<String, dynamic>> get events => _events.stream;
  bool get isConnected => _config != null;

  // --- connection lifecycle ---

  /// Verifies an FTP connection and, on success, remembers it as the active
  /// wireless device. Returns false (and emits nothing) if it can't connect.
  Future<bool> connect({
    required String host,
    required int port,
    required String user,
    required String pass,
  }) async {
    final ftp = FTPConnect(host,
        port: port, user: user, pass: pass, timeout: 15);
    try {
      final ok = await ftp.connect();
      if (!ok) return false;
      await ftp.disconnect();
    } catch (_) {
      try {
        await ftp.disconnect();
      } catch (_) {}
      return false;
    }
    _config = _WifiConfig(host: host, port: port, user: user, pass: pass);
    emitCurrent();
    return true;
  }

  /// Forget the active wireless device.
  void disconnect() {
    _config = null;
    emitCurrent();
  }

  /// (Re)emit the current device snapshot — used when this transport becomes
  /// active so the device list reflects the wireless connection immediately.
  void emitCurrent() {
    _events.add({'type': 'devicesChanged', 'devices': _deviceList()});
  }

  List<Map<String, dynamic>> _deviceList() {
    final cfg = _config;
    if (cfg == null) return const [];
    return [
      {
        'serial': wirelessSerial,
        'model': '${cfg.host} (Wi-Fi)',
        'state': 'device',
      }
    ];
  }

  // --- browse ---

  Future<List<FileEntry>> listDirectory(String path) async {
    final ftp = await _open();
    try {
      final entries = await _list(ftp, path);
      return entries.map((e) {
        final isDir = e.type == FTPEntryType.dir;
        return FileEntry(
          name: e.name,
          isDir: isDir,
          sizeBytes: e.size ?? 0,
          modifiedEpoch:
              (e.modifyTime?.millisecondsSinceEpoch ?? 0) ~/ 1000,
          isSymlink: e.type == FTPEntryType.link,
        );
      }).toList();
    } finally {
      await _quietClose(ftp);
    }
  }

  /// Lists [path] with MLSD (the connection default), falling back to LIST for
  /// servers that don't implement MLSD.
  Future<List<FTPEntry>> _list(FTPConnect ftp, String path) async {
    if (!await ftp.changeDirectory(path)) {
      throw 'Folder not found: $path';
    }
    try {
      return await ftp.listDirectoryContent();
    } catch (_) {
      ftp.listCommand = ListCommand.list;
      return await ftp.listDirectoryContent();
    }
  }

  // --- remote ops ---

  Future<void> deletePath(String path) async {
    final ftp = await _open();
    try {
      final parent = _parent(path);
      final name = _basename(path);
      final entries = await _list(ftp, parent);
      final match = entries.where((e) => e.name == name).toList();
      final isDir = match.isNotEmpty && match.first.type == FTPEntryType.dir;
      await ftp.changeDirectory(parent);
      if (isDir) {
        await ftp.deleteDirectory(name); // recursive in ftpconnect
      } else {
        await ftp.deleteFile(name);
      }
    } finally {
      await _quietClose(ftp);
    }
  }

  Future<void> makeDir(String path) async {
    final ftp = await _open();
    try {
      await _ensureRemoteDir(ftp, path);
    } finally {
      await _quietClose(ftp);
    }
  }

  /// FTP has no portable free-space query; return 0 so the UI's precheck (which
  /// already tolerates an unknown value) simply skips it.
  Future<int> freeSpace(String path) async => 0;

  // --- transfers (push/pull emit progress + done) ---

  void pushFile({
    required String localPath,
    required String remotePath,
    required String transferId,
  }) {
    unawaited(_runTransfer(transferId, (ftp) async {
      final entity = FileSystemEntity.typeSync(localPath);
      final total = _localSize(localPath);
      final progress = _progress(transferId, total);
      if (entity == FileSystemEntityType.directory) {
        var done = 0;
        await _uploadDir(ftp, Directory(localPath), remotePath, transferId,
            () => done, (v) => done = v, total, progress);
      } else {
        await _ensureRemoteDir(ftp, _parent(remotePath));
        await ftp.changeDirectory(_parent(remotePath));
        _throwIfCancelled(transferId);
        final ok = await ftp.uploadFile(File(localPath),
            sRemoteName: _basename(remotePath), onProgress: progress.forFile(0));
        if (!ok) throw 'Upload failed';
      }
      _emitProgress(transferId, total, total, 0);
    }));
  }

  void pullFile({
    required String remotePath,
    required String localPath,
    required String transferId,
  }) {
    unawaited(_runTransfer(transferId, (ftp) async {
      final parent = _parent(remotePath);
      final name = _basename(remotePath);
      final entries = await _list(ftp, parent);
      final match = entries.where((e) => e.name == name).toList();
      if (match.isNotEmpty && match.first.type == FTPEntryType.dir) {
        throw 'Cannot copy a folder';
      }
      final total = match.isNotEmpty ? (match.first.size ?? 0) : 0;
      final progress = _progress(transferId, total);
      await ftp.changeDirectory(parent);
      _throwIfCancelled(transferId);
      final ok = await ftp.downloadFile(name, File(localPath),
          onProgress: progress.forFile(0));
      if (!ok) throw 'Download failed';
    }, onError: () {
      // A killed download leaves a partial local file — remove it.
      try {
        File(localPath).deleteSync();
      } catch (_) {}
    }));
  }

  void cancel(String transferId) {
    _cancelled.add(transferId);
    // Aborting the socket makes the in-flight upload/download throw.
    final ftp = _active[transferId];
    if (ftp != null) unawaited(_quietClose(ftp));
  }

  // --- transfer plumbing ---

  Future<void> _runTransfer(String transferId, Future<void> Function(FTPConnect) body,
      {void Function()? onError}) async {
    FTPConnect ftp;
    try {
      ftp = await _open();
    } catch (e) {
      _emitDone(transferId, false, e.toString());
      return;
    }
    _active[transferId] = ftp;
    try {
      await body(ftp);
      _active.remove(transferId);
      _cancelled.remove(transferId);
      await _quietClose(ftp);
      _emitDone(transferId, true, null);
    } catch (e) {
      _active.remove(transferId);
      final wasCancelled = _cancelled.remove(transferId);
      await _quietClose(ftp);
      onError?.call();
      _emitDone(transferId, false, wasCancelled ? 'Cancelled' : e.toString());
    }
  }

  /// Recursively uploads [localDir] to [remoteDir], reporting aggregate byte
  /// progress across all files via [get]/[set] cumulative counters.
  Future<void> _uploadDir(
    FTPConnect ftp,
    Directory localDir,
    String remoteDir,
    String transferId,
    int Function() get,
    void Function(int) set,
    int total,
    _Progress progress,
  ) async {
    await _ensureRemoteDir(ftp, remoteDir);
    for (final child in localDir.listSync(followLinks: false)) {
      _throwIfCancelled(transferId);
      final name = _basename(child.path);
      final childRemote = '$remoteDir/$name';
      if (child is Directory) {
        await _uploadDir(
            ftp, child, childRemote, transferId, get, set, total, progress);
      } else if (child is File) {
        final base = get();
        await ftp.changeDirectory(remoteDir);
        final ok = await ftp.uploadFile(child,
            sRemoteName: name, onProgress: progress.forFile(base));
        if (!ok) throw 'Upload failed: $name';
        set(base + child.statSync().size);
      }
    }
  }

  // --- connection helpers ---

  Future<FTPConnect> _open() async {
    final cfg = _config;
    if (cfg == null) throw 'Not connected to a phone over Wi-Fi';
    final ftp = FTPConnect(cfg.host,
        port: cfg.port, user: cfg.user, pass: cfg.pass, timeout: 30);
    final ok = await ftp.connect();
    if (!ok) throw 'Could not reach ${cfg.host}:${cfg.port}';
    return ftp;
  }

  Future<void> _quietClose(FTPConnect ftp) async {
    try {
      await ftp.disconnect();
    } catch (_) {}
  }

  /// Ensures [path] exists on the server, creating each missing segment. FTP
  /// MKD semantics vary, so we walk from the root and create level by level.
  Future<void> _ensureRemoteDir(FTPConnect ftp, String path) async {
    if (path.isEmpty || path == '/') return;
    if (await ftp.changeDirectory(path)) return;
    var cur = '';
    for (final seg in path.split('/').where((s) => s.isNotEmpty)) {
      cur = '$cur/$seg';
      if (!await ftp.changeDirectory(cur)) {
        await ftp.changeDirectory(_parent(cur));
        await ftp.makeDirectory(seg);
      }
    }
  }

  void _throwIfCancelled(String transferId) {
    if (_cancelled.contains(transferId)) throw 'Cancelled';
  }

  // --- events ---

  _Progress _progress(String transferId, int total) =>
      _Progress(this, transferId, total);

  void _emitProgress(String id, int done, int total, int speed) {
    final pct = total > 0 ? (done / total * 100).clamp(0, 100).toInt() : 0;
    _events.add({
      'type': 'transferProgress',
      'transferId': id,
      'percent': pct,
      'bytesDone': done,
      'bytesTotal': total,
      'speedBps': speed,
    });
  }

  void _emitDone(String id, bool success, String? error) {
    _events.add({
      'type': 'transferDone',
      'transferId': id,
      'success': success,
      'error': ?error,
    });
  }

  // --- misc helpers ---

  int _localSize(String path) {
    try {
      final t = FileSystemEntity.typeSync(path);
      if (t == FileSystemEntityType.directory) {
        var sum = 0;
        for (final e in Directory(path).listSync(recursive: true, followLinks: false)) {
          if (e is File) sum += e.statSync().size;
        }
        return sum;
      }
      return File(path).statSync().size;
    } catch (_) {
      return 0;
    }
  }

  String _parent(String path) {
    final trimmed =
        path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
    final i = trimmed.lastIndexOf('/');
    if (i <= 0) return '/';
    return trimmed.substring(0, i);
  }

  String _basename(String path) {
    final trimmed =
        path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
    final i = trimmed.lastIndexOf('/');
    return i < 0 ? trimmed : trimmed.substring(i + 1);
  }
}

class _WifiConfig {
  final String host;
  final int port;
  final String user;
  final String pass;
  _WifiConfig(
      {required this.host,
      required this.port,
      required this.user,
      required this.pass});
}

/// Turns ftpconnect's per-file progress callbacks into throttled aggregate
/// `transferProgress` events (with computed speed). [baseBytes] offsets a file's
/// progress by the bytes already completed earlier in a multi-file transfer.
class _Progress {
  final WirelessService _svc;
  final String _id;
  final int _total;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastBytes = 0;
  DateTime _lastTime = DateTime.now();

  _Progress(this._svc, this._id, this._total);

  void Function(double, int, int) forFile(int baseBytes) {
    return (double _, int received, int _) {
      final done = baseBytes + received;
      final now = DateTime.now();
      if (now.difference(_lastEmit).inMilliseconds < 200 && done < _total) {
        return;
      }
      final dt = now.difference(_lastTime).inMilliseconds / 1000.0;
      final speed = dt > 0 ? ((done - _lastBytes) / dt).round() : 0;
      _lastBytes = done;
      _lastTime = now;
      _lastEmit = now;
      _svc._emitProgress(_id, done, _total, speed < 0 ? 0 : speed);
    };
  }
}
