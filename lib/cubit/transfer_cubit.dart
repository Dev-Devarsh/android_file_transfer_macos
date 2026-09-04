import 'dart:async';
import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/transfer.dart';
import '../services/platform_bridge.dart';

enum TransferMode { queue, parallel }

/// Observable state for the transfer queue: the transfers plus the current mode
/// and parallel cap (both persisted in native UserDefaults).
class TransferQueueState {
  final List<Transfer> transfers;
  final TransferMode mode;
  final int maxParallel;

  const TransferQueueState({
    this.transfers = const [],
    this.mode = TransferMode.queue,
    this.maxParallel = 3,
  });

  TransferQueueState copyWith({
    List<Transfer>? transfers,
    TransferMode? mode,
    int? maxParallel,
  }) {
    return TransferQueueState(
      transfers: transfers ?? this.transfers,
      mode: mode ?? this.mode,
      maxParallel: maxParallel ?? this.maxParallel,
    );
  }
}

/// Owns the transfer queue and dispatch policy.
///
/// - **Queue** mode: one transfer at a time (strict FIFO).
/// - **Parallel** mode: up to [maxParallel] transfers run concurrently.
///
/// Each transfer runs independently in the active transport (a native process
/// for MTP, an FTP connection for wireless), so concurrency is just a matter of
/// how many we start; progress/completion arrive on the shared event stream.
/// Mode + cap persist in UserDefaults.
class TransferCubit extends Cubit<TransferQueueState> {
  final PlatformBridge bridge;
  StreamSubscription<Map<String, dynamic>>? _sub;

  static const _modeKey = 'transferMode';
  static const _maxParallelKey = 'maxParallel';
  static const _autoClearDelay = Duration(seconds: 4);

  final _running = <String>{};
  final _completers = <String, Completer<String?>>{};
  var _counter = 0;
  bool _batchActive = false;

  TransferCubit(this.bridge) : super(const TransferQueueState()) {
    _sub = bridge.events().listen(_onEvent);
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    try {
      final mode = await bridge.getPref(_modeKey);
      final max = await bridge.getPref(_maxParallelKey);
      emit(state.copyWith(
        mode: mode == 'parallel' ? TransferMode.parallel : TransferMode.queue,
        maxParallel: (max is int && max > 0) ? max : state.maxParallel,
      ));
    } catch (_) {
      // Keep defaults if prefs can't be read.
    }
  }

  String _newId() => 't${DateTime.now().millisecondsSinceEpoch}_${_counter++}';

  // --- public: mode + cap ---

  void setMode(TransferMode mode) {
    if (mode == state.mode) return;
    emit(state.copyWith(mode: mode));
    bridge.setPref(_modeKey, mode == TransferMode.parallel ? 'parallel' : 'queue');
    // Switching to parallel releases the rest of the pending set; switching to
    // queue does NOT kill running transfers — they finish, then FIFO resumes.
    _pump();
  }

  void setMaxParallel(int value) {
    final v = value.clamp(1, 16);
    emit(state.copyWith(maxParallel: v));
    bridge.setPref(_maxParallelKey, v);
    _pump();
  }

  // --- public: enqueue ---

  void enqueuePush({
    required String serial,
    required String localPath,
    required String remotePath,
    required String name,
    required int sizeBytes,
  }) {
    _add(Transfer(
      id: _newId(),
      serial: serial,
      direction: TransferDirection.push,
      name: name,
      localPath: localPath,
      remotePath: remotePath,
      sizeBytes: sizeBytes,
    ));
  }

  void enqueuePull({
    required String serial,
    required String remotePath,
    required String localPath,
    required String name,
    required int sizeBytes,
  }) {
    _add(Transfer(
      id: _newId(),
      serial: serial,
      direction: TransferDirection.pull,
      name: name,
      localPath: localPath,
      remotePath: remotePath,
      sizeBytes: sizeBytes,
    ));
  }

  /// Pulls a remote file to a temp folder and completes with its local path
  /// (or null on failure). Used by drag-out to Finder.
  Future<String?> pullToTemp({
    required String serial,
    required String remotePath,
    required String name,
    required int sizeBytes,
  }) {
    final dir = Directory.systemTemp.createTempSync('filebridge_');
    final localPath = '${dir.path}/$name';
    final id = _newId();
    final completer = Completer<String?>();
    _completers[id] = completer;
    _add(Transfer(
      id: id,
      serial: serial,
      direction: TransferDirection.pull,
      name: name,
      localPath: localPath,
      remotePath: remotePath,
      sizeBytes: sizeBytes,
    ));
    return completer.future;
  }

  void _add(Transfer t) {
    _batchActive = true;
    emit(state.copyWith(transfers: [...state.transfers, t]));
    _pump();
  }

  void cancel(String id) {
    final t = _find(id);
    if (t == null) return;
    if (t.status == TransferStatus.queued) {
      _update(id, (x) => x.copyWith(status: TransferStatus.cancelled));
      _scheduleAutoClear(id);
      _pump();
    } else if (t.status == TransferStatus.running) {
      _update(id, (x) => x.copyWith(status: TransferStatus.cancelled));
      bridge.cancelTransfer(id);
    }
  }

  void clearFinished() => emit(
      state.copyWith(transfers: [for (final t in state.transfers) if (t.isActive) t]));

  // --- dispatch engine ---

  void _pump() {
    final allowed = state.mode == TransferMode.queue ? 1 : state.maxParallel;
    while (_running.length < allowed) {
      final next = _firstQueued();
      if (next == null) break;
      _running.add(next.id);
      _update(next.id, (t) => t.copyWith(status: TransferStatus.running));
      if (next.direction == TransferDirection.push) {
        bridge.pushFile(
          serial: next.serial,
          localPath: next.localPath,
          remotePath: next.remotePath,
          transferId: next.id,
        );
      } else {
        bridge.pullFile(
          serial: next.serial,
          remotePath: next.remotePath,
          localPath: next.localPath,
          transferId: next.id,
        );
      }
    }
    _maybeAnnounceBatchDone();
  }

  void _onEvent(Map<String, dynamic> e) {
    final id = e['transferId'] as String?;
    if (id == null) return;
    switch (e['type']) {
      case 'transferProgress':
        _update(id, (t) {
          final total = (e['bytesTotal'] as num?)?.toInt() ?? 0;
          return t.copyWith(
            percent: (e['percent'] as num?)?.toInt() ?? t.percent,
            bytesDone: (e['bytesDone'] as num?)?.toInt() ?? t.bytesDone,
            speedBps: (e['speedBps'] as num?)?.toInt() ?? t.speedBps,
            sizeBytes: total > 0 ? total : t.sizeBytes,
          );
        });
        break;
      case 'transferDone':
        final success = e['success'] == true;
        _update(id, (t) {
          if (t.status == TransferStatus.cancelled) return t;
          return t.copyWith(
            status: success ? TransferStatus.done : TransferStatus.failed,
            error: e['error'] as String?,
          );
        });
        _running.remove(id);
        final completer = _completers.remove(id);
        if (completer != null) {
          final t = _find(id);
          completer.complete(success ? t?.localPath : null);
        }
        _scheduleAutoClear(id);
        _pump();
        break;
    }
  }

  /// Auto-remove a finished transfer from the list after a short grace period
  /// (long enough to glance at the final % / error).
  void _scheduleAutoClear(String id) {
    Future.delayed(_autoClearDelay, () {
      if (isClosed) return;
      final t = _find(id);
      if (t != null && !t.isActive) {
        emit(state.copyWith(
            transfers: [for (final x in state.transfers) if (x.id != id) x]));
      }
    });
  }

  void _maybeAnnounceBatchDone() {
    if (!_batchActive) return;
    if (state.transfers.any((t) => t.isActive)) return;
    _batchActive = false;
    final done = state.transfers.where((t) => t.status == TransferStatus.done).length;
    final failed =
        state.transfers.where((t) => t.status == TransferStatus.failed).length;
    if (done == 0 && failed == 0) return;
    final parts = <String>[
      if (done > 0) '$done copied',
      if (failed > 0) '$failed failed',
    ];
    bridge.showNotification('Transfers complete', parts.join(', '));
  }

  // --- helpers ---

  Transfer? _find(String id) {
    for (final t in state.transfers) {
      if (t.id == id) return t;
    }
    return null;
  }

  Transfer? _firstQueued() {
    for (final t in state.transfers) {
      if (t.status == TransferStatus.queued) return t;
    }
    return null;
  }

  void _update(String id, Transfer Function(Transfer) fn) {
    emit(state.copyWith(
        transfers: [for (final t in state.transfers) if (t.id == id) fn(t) else t]));
  }

  @override
  Future<void> close() {
    _sub?.cancel();
    return super.close();
  }
}
