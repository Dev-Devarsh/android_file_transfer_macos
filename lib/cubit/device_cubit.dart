import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/device.dart';
import '../services/platform_bridge.dart';

class DeviceState {
  final List<Device> devices;
  final String? selectedSerial;

  const DeviceState({
    this.devices = const [],
    this.selectedSerial,
  });

  Device? get selected {
    for (final d in devices) {
      if (d.serial == selectedSerial) return d;
    }
    return null;
  }

  DeviceState copyWith({
    List<Device>? devices,
    String? selectedSerial,
  }) {
    return DeviceState(
      devices: devices ?? this.devices,
      selectedSerial: selectedSerial ?? this.selectedSerial,
    );
  }
}

/// Tracks connected devices via the shared event stream and remembers which one
/// the user has selected. Auto-selects a sensible default so the common
/// single-phone case needs no clicks.
class DeviceCubit extends Cubit<DeviceState> {
  final PlatformBridge _bridge;
  StreamSubscription<Map<String, dynamic>>? _sub;

  DeviceCubit(this._bridge) : super(const DeviceState()) {
    _sub = _bridge.events().listen(_onEvent);
  }

  void _onEvent(Map<String, dynamic> event) {
    if (event['type'] == 'devicesChanged') {
      final raw = (event['devices'] as List?) ?? const [];
      final devices = raw
          .map((e) => Device.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
      _applyDevices(devices);
    }
  }

  void _applyDevices(List<Device> devices) {
    // The active transport may re-send an identical list on every poll; skip if
    // nothing changed (and selection is still valid) to avoid churning the UI.
    final unchanged = devices.length == state.devices.length &&
        List.generate(devices.length, (i) => devices[i] == state.devices[i])
            .every((x) => x);
    if (unchanged &&
        (state.selectedSerial == null ||
            devices.any((d) => d.serial == state.selectedSerial))) {
      return;
    }

    var selected = state.selectedSerial;
    final stillPresent = devices.any((d) => d.serial == selected);
    if (!stillPresent) {
      // Prefer the first ready device, else the first device at all.
      selected = devices
              .where((d) => d.isReady)
              .map((d) => d.serial)
              .cast<String?>()
              .firstWhere((_) => true, orElse: () => null) ??
          (devices.isNotEmpty ? devices.first.serial : null);
    }
    emit(state.copyWith(
      devices: devices,
      selectedSerial: selected,
    ));
  }

  void select(String serial) => emit(state.copyWith(selectedSerial: serial));

  @override
  Future<void> close() {
    _sub?.cancel();
    return super.close();
  }
}
