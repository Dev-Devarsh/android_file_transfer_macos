enum TransferDirection { push, pull }

enum TransferStatus { queued, running, done, failed, cancelled }

/// One queued/active/finished file transfer, shown in the bottom queue panel.
class Transfer {
  final String id;
  final String serial;
  final TransferDirection direction;
  final String name;
  final String localPath;
  final String remotePath;
  final int sizeBytes;

  final TransferStatus status;
  final int percent;
  final int bytesDone;
  final int speedBps;
  final String? error;

  const Transfer({
    required this.id,
    required this.serial,
    required this.direction,
    required this.name,
    required this.localPath,
    required this.remotePath,
    required this.sizeBytes,
    this.status = TransferStatus.queued,
    this.percent = 0,
    this.bytesDone = 0,
    this.speedBps = 0,
    this.error,
  });

  bool get isActive =>
      status == TransferStatus.queued || status == TransferStatus.running;

  Transfer copyWith({
    int? sizeBytes,
    TransferStatus? status,
    int? percent,
    int? bytesDone,
    int? speedBps,
    Object? error = _unset,
  }) {
    return Transfer(
      id: id,
      serial: serial,
      direction: direction,
      name: name,
      localPath: localPath,
      remotePath: remotePath,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      status: status ?? this.status,
      percent: percent ?? this.percent,
      bytesDone: bytesDone ?? this.bytesDone,
      speedBps: speedBps ?? this.speedBps,
      error: error == _unset ? this.error : error as String?,
    );
  }

  static const _unset = Object();
}
