/// A single file or directory, used for both local (Mac) and remote (device)
/// entries so the panes can share one widget.
class FileEntry {
  final String name;
  final bool isDir;
  final int sizeBytes;

  /// Modified time in seconds since epoch (0 if unknown).
  final int modifiedEpoch;
  final bool isSymlink;

  const FileEntry({
    required this.name,
    required this.isDir,
    required this.sizeBytes,
    required this.modifiedEpoch,
    required this.isSymlink,
  });

  factory FileEntry.fromMap(Map<String, dynamic> map) => FileEntry(
        name: map['name'] as String? ?? '',
        isDir: map['isDir'] as bool? ?? false,
        sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
        modifiedEpoch: (map['modifiedEpoch'] as num?)?.toInt() ?? 0,
        isSymlink: map['isSymlink'] as bool? ?? false,
      );

  DateTime? get modified => modifiedEpoch == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(modifiedEpoch * 1000);
}
