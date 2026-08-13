import 'package:flutter_bloc/flutter_bloc.dart';

import '../services/platform_bridge.dart';
import '../transport/transport.dart';

/// Holds the active transport and keeps the native side + persisted preference
/// in sync. On startup it applies the saved transport so device discovery uses
/// the right monitor.
class TransportCubit extends Cubit<TransportKind> {
  final PlatformBridge bridge;
  static const _key = 'transport';

  TransportCubit(this.bridge) : super(TransportKind.mtp) {
    _load();
  }

  Future<void> _load() async {
    try {
      final saved = TransportKindX.fromWire(await bridge.getPref(_key));
      emit(saved);
      await bridge.setTransport(saved.wire);
    } catch (_) {
      await bridge.setTransport(TransportKind.mtp.wire);
    }
  }

  Future<void> setTransport(TransportKind kind) async {
    if (kind == state) return;
    emit(kind);
    await bridge.setTransport(kind.wire);
    await bridge.setPref(_key, kind.wire);
  }
}
