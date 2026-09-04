import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/file_entry.dart';
import '../transport/transport.dart';
import 'wireless_service.dart';

/// Thin façade over platform channels.
///
/// **macOS:** MTP (USB) is native; Wireless (FTP client) is in-process
/// [WirelessService]. Browse/transfer calls route to the active transport.
///
/// **Android:** native code is the FTP *server*. Flutter UI calls [ftpStart],
/// [ftpStop], etc. MTP methods are no-ops here.
///
/// All state is static so `const PlatformBridge()` remains a cheap, shareable
/// handle — every instance talks to the same channels and the same router.
class PlatformBridge {
  static const MethodChannel _commands = MethodChannel(
    'app.filebridge/commands',
  );
  static const EventChannel _events = EventChannel('app.filebridge/events');

  /// In-process wireless (FTP) *client* — macOS only.
  static final WirelessService _wireless = WirelessService();

  /// The transport browse/transfer calls route to. Kept in sync with the native
  /// side (and the persisted preference) by [setTransport].
  static TransportKind _active = TransportKind.mtp;

  /// ONE merged broadcast stream. On macOS: native MTP events + wireless
  /// events. On Android: FTP server state snapshots (`type: ftpState`).
  static final StreamController<Map<String, dynamic>> _merged =
      StreamController<Map<String, dynamic>>.broadcast();
  static bool _wired = false;

  const PlatformBridge();

  static void _ensureWired() {
    if (_wired) return;
    _wired = true;
    if (Platform.isMacOS) {
      _events
          .receiveBroadcastStream()
          .map((e) => Map<String, dynamic>.from(e as Map))
          .listen(_merged.add, onError: _merged.addError);
      _wireless.events.listen(_merged.add);
    } else if (Platform.isAndroid) {
      _events
          .receiveBroadcastStream()
          .map((e) => Map<String, dynamic>.from(e as Map))
          .listen(_merged.add, onError: _merged.addError);
    }
  }

  bool get _isWireless => _active == TransportKind.wireless;

  /// Broadcast stream of tagged events from the active native side.
  Stream<Map<String, dynamic>> events() {
    _ensureWired();
    return _merged.stream;
  }

  // --- transport switching (macOS) ---

  /// Switches the active transport ('mtp' or 'wireless'). The native side swaps
  /// its device monitor; the wireless side re-announces its current device.
  Future<void> setTransport(String transport) async {
    if (!Platform.isMacOS) return;
    _active = TransportKindX.fromWire(transport);
    await _commands.invokeMethod('setTransport', {'transport': transport});
    if (_isWireless) _wireless.emitCurrent();
  }

  // --- wireless connection (FTP client, macOS) ---

  Future<bool> wirelessConnect({
    required String host,
    required int port,
    required String user,
    required String pass,
  }) => _wireless.connect(host: host, port: port, user: user, pass: pass);

  void wirelessDisconnect() => _wireless.disconnect();

  bool get wirelessConnected => _wireless.isConnected;

  // --- directory listing (macOS) ---

  /// Lists a remote directory. Throws [PlatformException] on the native (MTP)
  /// path; the wireless path throws a plain error the browser surfaces.
  Future<List<FileEntry>> listDirectory(String serial, String path) async {
    if (!Platform.isMacOS) return const [];
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
    if (!Platform.isMacOS) return;
    if (_isWireless) {
      _wireless.pushFile(
        localPath: localPath,
        remotePath: remotePath,
        transferId: transferId,
      );
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
    if (!Platform.isMacOS) return;
    if (_isWireless) {
      _wireless.pullFile(
        remotePath: remotePath,
        localPath: localPath,
        transferId: transferId,
      );
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
    if (!Platform.isMacOS) return;
    if (_isWireless) {
      _wireless.cancel(transferId);
      return;
    }
    await _commands.invokeMethod('cancelTransfer', {'transferId': transferId});
  }

  // --- remote file ops (macOS) ---

  Future<void> deleteRemote(String serial, String path) async {
    if (!Platform.isMacOS) return;
    if (_isWireless) return _wireless.deletePath(path);
    await _commands.invokeMethod('deleteRemote', {
      'serial': serial,
      'path': path,
    });
  }

  Future<void> makeRemoteDir(String serial, String path) async {
    if (!Platform.isMacOS) return;
    if (_isWireless) return _wireless.makeDir(path);
    await _commands.invokeMethod('makeRemoteDir', {
      'serial': serial,
      'path': path,
    });
  }

  Future<int> remoteFreeSpace(String serial, String path) async {
    if (!Platform.isMacOS) return 0;
    if (_isWireless) return _wireless.freeSpace(path);
    final bytes = await _commands.invokeMethod<int>('remoteFreeSpace', {
      'serial': serial,
      'path': path,
    });
    return bytes ?? 0;
  }

  // --- native utilities (macOS) ---

  Future<void> showNotification(String title, String body) async {
    if (!Platform.isMacOS) return;
    await _commands.invokeMethod('showNotification', {
      'title': title,
      'body': body,
    });
  }

  /// Shows a native folder picker; returns the chosen directory path or null if
  /// cancelled. Used for the "Save to Mac…" export.
  Future<String?> chooseSaveDirectory() async {
    if (!Platform.isMacOS) return null;
    return _commands.invokeMethod<String>('chooseSaveDirectory');
  }

  Future<Object?> getPref(String key) async {
    if (!Platform.isMacOS) return null;
    return _commands.invokeMethod('getPref', {'key': key});
  }

  Future<void> setPref(String key, Object value) async {
    if (!Platform.isMacOS) return;
    await _commands.invokeMethod('setPref', {'key': key, 'value': value});
  }

  // --- FTP server (Android companion) ---

  Future<Map<String, dynamic>> ftpGetState() async {
    if (!Platform.isAndroid) return const {};
    final result = await _commands.invokeMethod<Map>('ftpGetState');
    return Map<String, dynamic>.from(result ?? const {});
  }

  Future<void> ftpStart({
    required int port,
    required String user,
    required String pass,
  }) async {
    if (!Platform.isAndroid) return;
    await _commands.invokeMethod('ftpStart', {
      'port': port,
      'user': user,
      'pass': pass,
    });
  }

  Future<void> ftpStop() async {
    if (!Platform.isAndroid) return;
    await _commands.invokeMethod('ftpStop');
  }

  Future<void> ftpClearLog() async {
    if (!Platform.isAndroid) return;
    await _commands.invokeMethod('ftpClearLog');
  }

  Future<void> ftpRequestStorage() async {
    if (!Platform.isAndroid) return;
    await _commands.invokeMethod('ftpRequestStorage');
  }

  Future<void> ftpRequestNotifications() async {
    if (!Platform.isAndroid) return;
    await _commands.invokeMethod('ftpRequestNotifications');
  }
}
