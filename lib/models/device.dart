/// A connected device, normalized across transports. For MTP this comes from
/// the native libmtp layer; for the wireless (FTP) transport it's the phone we
/// connected to over Wi-Fi. The field names are kept generic so one model can
/// serve every transport.
class Device {
  final String serial;
  final String model;

  /// One of: `device`, `unauthorized`, `offline`, `no permissions`, `unknown`.
  /// The wireless and MTP transports only ever report `device`.
  final String state;

  const Device({
    required this.serial,
    required this.model,
    required this.state,
  });

  factory Device.fromMap(Map<String, dynamic> map) => Device(
        serial: map['serial'] as String? ?? '',
        model: map['model'] as String? ?? '',
        state: map['state'] as String? ?? 'unknown',
      );

  /// True only when the device is fully usable for file operations.
  bool get isReady => state == 'device';

  String get displayName =>
      model.isNotEmpty ? model.replaceAll('_', ' ') : serial;

  @override
  bool operator ==(Object other) =>
      other is Device &&
      other.serial == serial &&
      other.model == model &&
      other.state == state;

  @override
  int get hashCode => Object.hash(serial, model, state);
}
