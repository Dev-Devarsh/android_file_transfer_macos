import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../cubit/browser_cubit.dart';
import '../models/file_entry.dart';
import 'format.dart';

/// The device file browser (single pane). Files can be dragged out to Finder
/// and right-clicked to "Save to Mac…"; both are wired via the callbacks.
class FilePane extends StatelessWidget {
  final BrowserCubit cubit;

  /// Builds a drag payload for a file being dragged to Finder (null = no drag).
  final Future<DragItem?> Function(FileEntry entry)? dragItemProvider;

  /// Invoked from the row's right-click "Save to Mac…" menu.
  final void Function(FileEntry entry)? onExportToMac;

  /// Invoked from the row's right-click "Delete" menu.
  final void Function(FileEntry entry)? onDelete;

  /// Invoked by the toolbar "New Folder" button.
  final VoidCallback? onNewFolder;

  const FilePane({
    super.key,
    required this.cubit,
    this.dragItemProvider,
    this.onExportToMac,
    this.onDelete,
    this.onNewFolder,
  });

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<BrowserCubit, BrowserState>(
      bloc: cubit,
      builder: (context, state) {
        return Column(
          children: [
            _Toolbar(cubit: cubit, state: state, onNewFolder: onNewFolder),
            const Divider(height: 1),
            _Breadcrumb(cubit: cubit, state: state),
            const Divider(height: 1),
            if (state.loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(child: _body(context, state)),
          ],
        );
      },
    );
  }

  Widget _body(BuildContext context, BrowserState state) {
    if (state.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.report_gmailerrorred,
                  color: Theme.of(context).colorScheme.error, size: 40),
              const SizedBox(height: 12),
              Text(state.error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: cubit.refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (state.entries.isEmpty && !state.loading) {
      return const Center(child: Text('Empty folder'));
    }

    return ListView.builder(
      itemCount: state.entries.length,
      itemBuilder: (context, i) {
        final entry = state.entries[i];
        return _EntryRow(
          entry: entry,
          selected: entry.name == state.selectedName,
          onTap: () => cubit.select(entry.name),
          onDoubleTap: () => entry.isDir ? cubit.open(entry) : null,
          dragItemProvider: dragItemProvider,
          onExportToMac: onExportToMac,
          onDelete: onDelete,
        );
      },
    );
  }
}

class _Toolbar extends StatelessWidget {
  final BrowserCubit cubit;
  final BrowserState state;
  final VoidCallback? onNewFolder;
  const _Toolbar({required this.cubit, required this.state, this.onNewFolder});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            iconSize: 18,
            tooltip: 'Up',
            onPressed: cubit.goUp,
            icon: const Icon(Icons.arrow_upward),
          ),
          IconButton(
            iconSize: 18,
            tooltip: 'Home',
            onPressed: cubit.goHome,
            icon: const Icon(Icons.home_outlined),
          ),
          IconButton(
            iconSize: 18,
            tooltip: 'Refresh',
            onPressed: cubit.refresh,
            icon: const Icon(Icons.refresh),
          ),
          if (onNewFolder != null)
            IconButton(
              iconSize: 18,
              tooltip: 'New folder',
              onPressed: onNewFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
          const Spacer(),
          PopupMenuButton<SortKey>(
            iconSize: 18,
            tooltip: 'Sort',
            icon: const Icon(Icons.sort),
            onSelected: cubit.setSort,
            itemBuilder: (context) => [
              _sortItem(SortKey.name, 'Name'),
              _sortItem(SortKey.size, 'Size'),
              _sortItem(SortKey.modified, 'Modified'),
            ],
          ),
        ],
      ),
    );
  }

  PopupMenuItem<SortKey> _sortItem(SortKey key, String label) {
    final active = state.sortKey == key;
    return PopupMenuItem(
      value: key,
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: active
                ? Icon(state.ascending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 14)
                : null,
          ),
          Text(label),
        ],
      ),
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  final BrowserCubit cubit;
  final BrowserState state;
  const _Breadcrumb({required this.cubit, required this.state});

  @override
  Widget build(BuildContext context) {
    final segments = _segments(state.path);
    return Container(
      height: 34,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: Row(
          children: [
            for (var i = 0; i < segments.length; i++) ...[
              if (i > 0)
                const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
              InkWell(
                onTap: () => cubit.navigateTo(segments[i].path),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Text(
                    segments[i].label,
                    style: TextStyle(
                      fontWeight: i == segments.length - 1
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<({String label, String path})> _segments(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    final result = <({String label, String path})>[
      (label: '/', path: '/'),
    ];
    var acc = '';
    for (final part in parts) {
      acc = '$acc/$part';
      result.add((label: part, path: acc));
    }
    return result;
  }
}

class _EntryRow extends StatelessWidget {
  final FileEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;
  final Future<DragItem?> Function(FileEntry entry)? dragItemProvider;
  final void Function(FileEntry entry)? onExportToMac;
  final void Function(FileEntry entry)? onDelete;

  const _EntryRow({
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
    this.dragItemProvider,
    this.onExportToMac,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget row = Container(
      height: 32,
      color: selected ? scheme.primaryContainer : null,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(_icon, size: 16, color: _iconColor(scheme)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontStyle: entry.isSymlink ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
          SizedBox(
            width: 74,
            child: Text(
              entry.isDir ? '' : formatBytes(entry.sizeBytes),
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 130,
            child: Text(
              formatDate(entry.modified),
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );

    Widget interactive = InkWell(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      child: row,
    );

    // Right-click → context menu (Save to Mac… for files, Delete for anything).
    final canExport = onExportToMac != null && !entry.isDir;
    if (canExport || onDelete != null) {
      interactive = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (d) => _showMenu(context, d.globalPosition, canExport),
        child: interactive,
      );
    }

    // Drag out to Finder (files only).
    if (dragItemProvider != null && !entry.isDir) {
      interactive = DragItemWidget(
        allowedOperations: () => [DropOperation.copy],
        dragItemProvider: (_) => dragItemProvider!(entry),
        child: DraggableWidget(child: interactive),
      );
    }

    return interactive;
  }

  Future<void> _showMenu(
      BuildContext context, Offset globalPos, bool canExport) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPos & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        if (canExport)
          const PopupMenuItem(value: 'save', child: Text('Save to Mac…')),
        if (onDelete != null)
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
    if (selected == 'save') {
      onExportToMac?.call(entry);
    } else if (selected == 'delete') {
      onDelete?.call(entry);
    }
  }

  IconData get _icon {
    if (entry.isSymlink) return Icons.link;
    return entry.isDir ? Icons.folder : Icons.insert_drive_file_outlined;
  }

  Color _iconColor(ColorScheme scheme) =>
      entry.isDir ? scheme.primary : scheme.onSurfaceVariant;
}
