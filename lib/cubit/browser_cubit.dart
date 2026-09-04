import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/file_entry.dart';
import '../services/file_source.dart';
// RemoteSource is the only source now (device-only browser).

enum SortKey { name, size, modified }

class BrowserState {
  final String path;
  final List<FileEntry> entries;
  final bool loading;
  final String? error;
  final SortKey sortKey;
  final bool ascending;

  /// The "anchor" selection — the last row clicked. Drives single-file actions
  /// (context menu) and is the pivot for shift-click range selection.
  final String? selectedName;

  /// All currently-selected rows (for multi-select + multi-drag). Always
  /// contains [selectedName] when a selection exists.
  final Set<String> selectedNames;

  const BrowserState({
    required this.path,
    this.entries = const [],
    this.loading = false,
    this.error,
    this.sortKey = SortKey.name,
    this.ascending = true,
    this.selectedName,
    this.selectedNames = const {},
  });

  FileEntry? get selected {
    for (final e in entries) {
      if (e.name == selectedName) return e;
    }
    return null;
  }

  /// The selected entries, in the pane's current display order.
  List<FileEntry> get selectedEntries =>
      [for (final e in entries) if (selectedNames.contains(e.name)) e];

  bool isSelected(String name) => selectedNames.contains(name);

  BrowserState copyWith({
    String? path,
    List<FileEntry>? entries,
    bool? loading,
    Object? error = _unset,
    SortKey? sortKey,
    bool? ascending,
    Object? selectedName = _unset,
    Set<String>? selectedNames,
  }) {
    return BrowserState(
      path: path ?? this.path,
      entries: entries ?? this.entries,
      loading: loading ?? this.loading,
      error: error == _unset ? this.error : error as String?,
      sortKey: sortKey ?? this.sortKey,
      ascending: ascending ?? this.ascending,
      selectedName:
          selectedName == _unset ? this.selectedName : selectedName as String?,
      selectedNames: selectedNames ?? this.selectedNames,
    );
  }

  static const _unset = Object();
}

/// Drives a single pane. Both panes use this; only the [FileSource] differs.
class BrowserCubit extends Cubit<BrowserState> {
  RemoteSource source;

  BrowserCubit(this.source)
      : super(BrowserState(path: source.initialPath, loading: true)) {
    load(source.initialPath);
  }

  Future<void> load(String path) async {
    emit(state.copyWith(
        loading: true,
        error: null,
        path: path,
        selectedName: null,
        selectedNames: const {}));
    try {
      final entries = await source.list(path);
      emit(state.copyWith(
        entries: _sorted(entries, state.sortKey, state.ascending),
        loading: false,
      ));
    } on PlatformException catch (e) {
      emit(state.copyWith(loading: false, error: e.message ?? e.code));
    } catch (e) {
      emit(state.copyWith(loading: false, error: e.toString()));
    }
  }

  void refresh() => load(state.path);
  void goHome() => load(source.initialPath);

  void goUp() {
    final parent = source.parentOf(state.path);
    if (parent != state.path) load(parent);
  }

  void navigateTo(String path) => load(path);

  void open(FileEntry entry) {
    if (entry.isDir) load(source.join(state.path, entry.name));
  }

  /// Plain click: select exactly this row (clears any other selection).
  void select(String? name) => emit(state.copyWith(
        selectedName: name,
        selectedNames: name == null ? const {} : {name},
      ));

  /// Cmd/Ctrl-click: toggle this row in the selection, keeping the rest.
  void toggleSelect(String name) {
    final next = {...state.selectedNames};
    if (!next.remove(name)) next.add(name);
    emit(state.copyWith(
      selectedNames: next,
      selectedName: next.contains(name) ? name : null,
    ));
  }

  /// Shift-click: select the contiguous range from the anchor to [name]
  /// (in the current display order), unioned with the existing selection.
  void selectTo(String name) {
    final anchor = state.selectedName;
    if (anchor == null) {
      select(name);
      return;
    }
    final order = [for (final e in state.entries) e.name];
    final a = order.indexOf(anchor);
    final b = order.indexOf(name);
    if (a < 0 || b < 0) {
      select(name);
      return;
    }
    final lo = a < b ? a : b;
    final hi = a < b ? b : a;
    emit(state.copyWith(
      selectedNames: {...state.selectedNames, ...order.sublist(lo, hi + 1)},
      selectedName: name,
    ));
  }

  Future<void> deletePath(String name) async {
    try {
      await source.bridge
          .deleteRemote(source.serial, source.join(state.path, name));
      await load(state.path);
    } on PlatformException catch (e) {
      emit(state.copyWith(error: e.message ?? e.code));
    }
  }

  Future<void> makeDir(String name) async {
    try {
      await source.bridge
          .makeRemoteDir(source.serial, source.join(state.path, name));
      await load(state.path);
    } on PlatformException catch (e) {
      emit(state.copyWith(error: e.message ?? e.code));
    }
  }

  void setSort(SortKey key) {
    final ascending = key == state.sortKey ? !state.ascending : true;
    emit(state.copyWith(
      sortKey: key,
      ascending: ascending,
      entries: _sorted(state.entries, key, ascending),
    ));
  }

  /// Swap the underlying source (e.g. the selected device changed) and reload.
  void changeSource(RemoteSource newSource) {
    source = newSource;
    load(newSource.initialPath);
  }

  static List<FileEntry> _sorted(List<FileEntry> input, SortKey key, bool asc) {
    final list = [...input];
    list.sort((a, b) {
      // Directories always come before files.
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      int c;
      switch (key) {
        case SortKey.name:
          c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case SortKey.size:
          c = a.sizeBytes.compareTo(b.sizeBytes);
          break;
        case SortKey.modified:
          c = a.modifiedEpoch.compareTo(b.modifiedEpoch);
          break;
      }
      return asc ? c : -c;
    });
    return list;
  }
}
