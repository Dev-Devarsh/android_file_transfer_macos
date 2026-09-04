import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../services/platform_bridge.dart';

class FtpServerState {
  final bool running;
  final String? host;
  final int port;
  final String user;
  final String rootPath;
  final bool hasStorageAccess;
  final List<String> log;
  final String? error;
  final bool busy;

  const FtpServerState({
    this.running = false,
    this.host,
    this.port = 2121,
    this.user = 'anonymous',
    this.rootPath = '',
    this.hasStorageAccess = false,
    this.log = const [],
    this.error,
    this.busy = false,
  });

  FtpServerState copyWith({
    bool? running,
    String? host,
    int? port,
    String? user,
    String? rootPath,
    bool? hasStorageAccess,
    List<String>? log,
    String? error,
    bool? busy,
    bool clearError = false,
  }) {
    return FtpServerState(
      running: running ?? this.running,
      host: host ?? this.host,
      port: port ?? this.port,
      user: user ?? this.user,
      rootPath: rootPath ?? this.rootPath,
      hasStorageAccess: hasStorageAccess ?? this.hasStorageAccess,
      log: log ?? this.log,
      error: clearError ? null : (error ?? this.error),
      busy: busy ?? this.busy,
    );
  }
}

/// Mirrors native [ServerBus] state for the Android FTP companion UI.
class FtpServerCubit extends Cubit<FtpServerState> {
  final PlatformBridge _bridge;
  StreamSubscription<Map<String, dynamic>>? _sub;

  FtpServerCubit(this._bridge) : super(const FtpServerState()) {
    _sub = _bridge.events().listen(_onEvent);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _bridge.ftpRequestNotifications();
    try {
      _apply(await _bridge.ftpGetState());
    } catch (_) {}
  }

  void _onEvent(Map<String, dynamic> event) {
    if (event['type'] == 'ftpState') _apply(event);
  }

  void _apply(Map<String, dynamic> map) {
    if (map.isEmpty) return;
    emit(
      state.copyWith(
        running: map['running'] as bool? ?? false,
        host: map['host'] as String?,
        port: (map['port'] as num?)?.toInt() ?? state.port,
        user: map['user'] as String? ?? state.user,
        rootPath: map['rootPath'] as String? ?? state.rootPath,
        hasStorageAccess: map['hasStorageAccess'] as bool? ?? false,
        log:
            (map['log'] as List?)?.map((e) => e.toString()).toList() ??
            state.log,
        busy: false,
        clearError: true,
      ),
    );
  }

  Future<void> start({
    required int port,
    required String user,
    required String pass,
  }) async {
    emit(state.copyWith(busy: true, clearError: true));
    try {
      await _bridge.ftpStart(port: port, user: user, pass: pass);
    } on PlatformException catch (e) {
      emit(state.copyWith(busy: false, error: e.message ?? e.code));
    } catch (e) {
      emit(state.copyWith(busy: false, error: e.toString()));
    }
  }

  Future<void> stop() async {
    emit(state.copyWith(busy: true, clearError: true));
    try {
      await _bridge.ftpStop();
    } catch (e) {
      emit(state.copyWith(busy: false, error: e.toString()));
    }
  }

  Future<void> clearLog() => _bridge.ftpClearLog();

  Future<void> requestStorage() => _bridge.ftpRequestStorage();

  void reportError(String message) =>
      emit(state.copyWith(error: message, busy: false));

  @override
  Future<void> close() {
    _sub?.cancel();
    return super.close();
  }
}
