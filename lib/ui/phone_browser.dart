import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../cubit/browser_cubit.dart';
import '../cubit/transfer_cubit.dart';
import '../models/file_entry.dart';
import '../models/transfer.dart';
import '../services/file_source.dart';
import '../services/platform_bridge.dart';
import '../services/settings_service.dart';
import '../transport/transport.dart';
import 'file_pane.dart';
import 'format.dart';
import 'transfer_panel.dart';

/// The whole working area once a device is ready: the device file browser with
/// Finder drag & drop, plus the transfer queue panel underneath.
class PhoneBrowser extends StatefulWidget {
  final PlatformBridge bridge;
  final String serial;
  final String deviceName;
  final TransportKind transport;

  const PhoneBrowser({
    super.key,
    required this.bridge,
    required this.serial,
    required this.deviceName,
    required this.transport,
  });

  @override
  State<PhoneBrowser> createState() => _PhoneBrowserState();
}

class _PhoneBrowserState extends State<PhoneBrowser> {
  final _settings = SettingsService();
  late BrowserCubit _remote;
  StreamSubscription<BrowserState>? _pathSaver;
  bool _dragging = false;

  /// Transfers we've already auto-refreshed for, so we reload the folder once.
  final _refreshedFor = <String>{};

  @override
  void initState() {
    super.initState();
    _remote = BrowserCubit(_source());

    // Restore the last-visited directory for THIS transport, if any.
    final last = _settings.lastRemotePathFor(widget.transport.wire);
    if (last != null && last.isNotEmpty && last != _remote.state.path) {
      _remote.navigateTo(last);
    }
    // Persist the directory (per transport) whenever it changes.
    var saved = _remote.state.path;
    _pathSaver = _remote.stream.listen((s) {
      if (s.path != saved) {
        saved = s.path;
        _settings.setLastRemotePath(widget.transport.wire, s.path);
      }
    });
  }

  RemoteSource _source() => RemoteSource(
        bridge: widget.bridge,
        serial: widget.serial,
        deviceName: widget.deviceName,
        initialPath: widget.transport.initialPath,
      );

  @override
  void didUpdateWidget(covariant PhoneBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serial != widget.serial ||
        oldWidget.deviceName != widget.deviceName ||
        oldWidget.transport != widget.transport) {
      _remote.changeSource(_source());
      // Restore this transport's remembered directory (falls back to its root).
      final last = _settings.lastRemotePathFor(widget.transport.wire);
      if (last != null && last.isNotEmpty && last != widget.transport.initialPath) {
        _remote.navigateTo(last);
      }
    }
  }

  @override
  void dispose() {
    _pathSaver?.cancel();
    _remote.close();
    super.dispose();
  }

  String _join(String dir, String name) =>
      dir == '/' ? '/$name' : '$dir/$name';

  TransferCubit get _transfers => context.read<TransferCubit>();

  // --- Finder → phone (import / push) ---

  Future<void> _onDrop(DropDoneDetails detail) async {
    setState(() => _dragging = false);
    final remoteDir = _remote.state.path;

    final toPush = <({String path, String name, int size})>[];
    var totalFiles = 0;
    for (final dropped in detail.files) {
      final name = dropped.name.isNotEmpty ? dropped.name : _leaf(dropped.path);
      final entity = FileSystemEntity.typeSync(dropped.path);
      if (entity == FileSystemEntityType.directory) {
        // The wireless transport uploads folders recursively; skip size here
        // (measured per-file during the transfer, so no upfront precheck).
        toPush.add((path: dropped.path, name: name, size: 0));
      } else {
        final size = File(dropped.path).statSync().size;
        toPush.add((path: dropped.path, name: name, size: size));
        totalFiles += size;
      }
    }
    if (toPush.isEmpty) return;

    // Free-space precheck for the file bytes we can measure.
    if (totalFiles > 0) {
      try {
        final free = await widget.bridge.remoteFreeSpace(widget.serial, remoteDir);
        if (free > 0 && totalFiles > free) {
          _snack('Not enough space: need ${formatBytes(totalFiles)}, '
              '${formatBytes(free)} free on device.');
          return;
        }
      } catch (_) {
        // If df fails, don't block the transfer.
      }
    }

    for (final f in toPush) {
      _transfers.enqueuePush(
        serial: widget.serial,
        localPath: f.path,
        remotePath: _join(remoteDir, f.name),
        name: f.name,
        sizeBytes: f.size,
      );
    }
  }

  // --- phone → Mac (export / pull) ---

  Future<DragItem?> _dragOut(FileEntry entry) async {
    final localPath = await _transfers.pullToTemp(
      serial: widget.serial,
      remotePath: _join(_remote.state.path, entry.name),
      name: entry.name,
      sizeBytes: entry.sizeBytes,
    );
    if (localPath == null) return null;
    final item = DragItem(suggestedName: entry.name);
    item.add(Formats.fileUri(Uri.file(localPath)));
    return item;
  }

  Future<void> _saveToMac(FileEntry entry) async {
    final dir = await widget.bridge.chooseSaveDirectory();
    if (dir == null) return;
    _transfers.enqueuePull(
      serial: widget.serial,
      remotePath: _join(_remote.state.path, entry.name),
      localPath: _join(dir, entry.name),
      name: entry.name,
      sizeBytes: entry.sizeBytes,
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // --- delete / new folder ---

  Future<void> _confirmDelete(FileEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${entry.name}"?'),
        content: Text(entry.isDir
            ? 'This folder and everything in it will be deleted from the device.'
            : 'This file will be deleted from the device.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) _remote.deletePath(entry.name);
  }

  Future<void> _newFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Folder name'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Create')),
        ],
      ),
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isNotEmpty) _remote.makeDir(trimmed);
  }

  String _leaf(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  String _parentDir(String remotePath) {
    final i = remotePath.lastIndexOf('/');
    if (i <= 0) return '/';
    return remotePath.substring(0, i);
  }

  /// Reload the open folder once when a Mac→phone push into it finishes.
  void _onTransfersChanged(TransferQueueState state) {
    var needsRefresh = false;
    for (final t in state.transfers) {
      if (t.status != TransferStatus.done) continue;
      if (t.direction != TransferDirection.push) continue;
      if (!_refreshedFor.add(t.id)) continue;
      if (_parentDir(t.remotePath) == _remote.state.path) {
        needsRefresh = true;
      }
    }
    if (needsRefresh) _remote.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<TransferCubit, TransferQueueState>(
      listener: (_, state) => _onTransfersChanged(state),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyR, meta: true):
              _remote.refresh,
          const SingleActivator(LogicalKeyboardKey.backspace): () {
            final sel = _remote.state.selected;
            if (sel != null) _confirmDelete(sel);
          },
        },
        child: Focus(
          autofocus: true,
          child: Column(
            children: [
              Expanded(
                child: DropTarget(
                  onDragEntered: (_) => setState(() => _dragging = true),
                  onDragExited: (_) => setState(() => _dragging = false),
                  onDragDone: _onDrop,
                  child: Stack(
                    children: [
                      FilePane(
                        cubit: _remote,
                        dragItemProvider: _dragOut,
                        onExportToMac: _saveToMac,
                        onDelete: _confirmDelete,
                        onNewFolder: _newFolder,
                      ),
                      if (_dragging) _dropHint(context),
                    ],
                  ),
                ),
              ),
              const TransferPanel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dropHint(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: scheme.primary.withValues(alpha: 0.08),
          child: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.primary, width: 2),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.download, size: 40, color: scheme.primary),
                const SizedBox(height: 8),
                Text('Drop to copy to ${_remote.state.path}',
                    style: TextStyle(
                        color: scheme.primary, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
