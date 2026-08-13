import 'dart:async';

import 'package:flutter/services.dart';

import '../models/file_entry.dart';
import '../transport/transport.dart';
import 'wireless_service.dart';


/// Thin façade over the two transports. MTP (USB) is handled natively via the
/// method/event channels; Wireless (FTP over Wi-Fi) is handled in-process by
/// [WirelessService]. This class routes every browse/transfer call to the
/// active transport and merges both sides' events into one stream, so the
/// cubits and UI never need to know which transport is live.
///
/// All state is static so `const PlatformBridge()` remains a cheap, shareable
/// handle — every instance talks to the same channels and the same router.
class PlatformBridge {
  static const MethodChannel _commands = MethodChannel('app.filebridge/commands');
  static const EventChannel _events = EventChannel('app.filebridge/events');

  /// In-process wireless (FTP) transport.
  static final WirelessService _wireless = WirelessService();

  /// The transport browse/transfer calls route to. Kept in sync with the native
  /// side (and the persisted preference) by [setTransport].
  static TransportKind _active = TransportKind.mtp;

  /// ONE merged broadcast stream carrying both native events (device changes +
  /// MTP transfer progress) and wireless events (in the identical shapes).
  /// Every subscriber shares it; the native channel is subscribed exactly once.
  static final StreamController<Map<String, dynamic>> _merged =
      StreamController<Map<String, dynamic>>.broadcast();
  static bool _wired = false;

  const PlatformBridge();

  static void _ensureWired() {
    if (_wired) return;
    _wired = true;
    _events
        .receiveBroadcastStream()
        .map((e) => Map<String, dynamic>.from(e as Map))
        .listen(_merged.add, onError: _merged.addError);
    _wireless.events.listen(_merged.add);
  }

  bool get _isWireless => _active == TransportKind.wireless;

  /// Broadcast stream of tagged events (`devicesChanged`, `transferProgress`,
  /// `transferDone`) from whichever transport is active.
  Stream<Map<String, dynamic>> events() {
    _ensureWired();
    return _merged.stream;
  }

  // --- transport switching ---

  /// Switches the active transport ('mtp' or 'wireless'). The native side swaps
  /// its device monitor; the wireless side re-announces its current device.
  Future<void> setTransport(String transport) async {
    _active = TransportKindX.fromWire(transport);
    await _commands.invokeMethod('setTransport', {'transport': transport});
    if (_isWireless) _wireless.emitCurrent();
  }

  // --- wireless connection (FTP) ---

  Future<bool> wirelessConnect({
    required String host,
    required int port,
    required String user,
    required String pass,
  }) =>
      _wireless.connect(host: host, port: port, user: user, pass: pass);

  void wirelessDisconnect() => _wireless.disconnect();

  bool get wirelessConnected => _wireless.isConnected;

  // --- directory listing ---

  /// Lists a remote directory. Throws [PlatformException] on the native (MTP)
  /// path; the wireless path throws a plain error the browser surfaces.
  Future<List<FileEntry>> listDirectory(String serial, String path) async {
    if (_isWireless) return _wireless.listDirectory(path);
    final result = await _commands.invokeMethod<List<dynamic>>(
      'listDirectory',
      {'serial': serial, 'path': path},
    );
    return (result ?? [])
        .map((e) => FileEntry.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  // --- transfers (progress/done arrive via [events]) ---

  Future<void> pushFile({
    required String serial,
    required String localPath,
    required String remotePath,
    required String transferId,
  }) async {
    if (_isWireless) {
      _wireless.pushFile(
          localPath: localPath, remotePath: remotePath, transferId: transferId);
      return;
    }
    await _commands.invokeMethod('pushFile', {
      'serial': serial,
      'localPath': localPath,
      'remotePath': remotePath,
      'transferId': transferId,
    });
  }

  Future<void> pullFile({
    required String serial,
    required String remotePath,
    required String localPath,
    required String transferId,
  }) async {
    if (_isWireless) {
      _wireless.pullFile(
          remotePath: remotePath, localPath: localPath, transferId: transferId);
      return;
    }
    await _commands.invokeMethod('pullFile', {
      'serial': serial,
      'remotePath': remotePath,
      'localPath': localPath,
      'transferId': transferId,
    });
  }

  Future<void> cancelTransfer(String transferId) async {
    if (_isWireless) {
      _wireless.cancel(transferId);
      return;
    }
    await _commands.invokeMethod('cancelTransfer', {'transferId': transferId});
  }

  // --- remote file ops ---

  Future<void> deleteRemote(String serial, String path) async {
    if (_isWireless) return _wireless.deletePath(path);
    await _commands.invokeMethod('deleteRemote', {'serial': serial, 'path': path});
  }

  Future<void> makeRemoteDir(String serial, String path) async {
    if (_isWireless) return _wireless.makeDir(path);
    await _commands.invokeMethod('makeRemoteDir', {'serial': serial, 'path': path});
  }

  Future<int> remoteFreeSpace(String serial, String path) async {
    if (_isWireless) return _wireless.freeSpace(path);
    final bytes = await _commands.invokeMethod<int>(
        'remoteFreeSpace', {'serial': serial, 'path': path});
    return bytes ?? 0;
  }

  // --- native utilities (transport-independent) ---

  Future<void> showNotification(String title, String body) =>
      _commands.invokeMethod('showNotification', {'title': title, 'body': body});

  /// Shows a native folder picker; returns the chosen directory path or null if
  /// cancelled. Used for the "Save to Mac…" export.
  Future<String?> chooseSaveDirectory() =>
      _commands.invokeMethod<String>('chooseSaveDirectory');

  // --- native UserDefaults-backed preferences ---

  Future<Object?> getPref(String key) =>
      _commands.invokeMethod('getPref', {'key': key});

  Future<void> setPref(String key, Object value) =>
      _commands.invokeMethod('setPref', {'key': key, 'value': value});
}
