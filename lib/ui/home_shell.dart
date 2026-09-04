import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../cubit/device_cubit.dart';
import '../cubit/transfer_cubit.dart';
import '../cubit/transport_cubit.dart';
import '../models/device.dart';
import '../services/platform_bridge.dart';
import '../transport/transport.dart';
import 'phone_browser.dart';
import 'wireless_dialog.dart';

/// Top-level window content: a device bar across the top, and a body that
/// reacts to the selected device's state. In Phase 2 the "ready" body becomes
/// the dual-pane browser.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const _DeviceBar(),
          const Divider(height: 1),
          Expanded(
            child: BlocBuilder<DeviceCubit, DeviceState>(
              builder: (context, state) => _buildBody(context, state),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, DeviceState state) {
    if (state.devices.isEmpty) {
      return BlocBuilder<TransportCubit, TransportKind>(
        builder: (context, transport) => _CenteredMessage(
          icon: transport == TransportKind.wireless ? Icons.wifi : Icons.usb,
          title: 'No device connected',
          message: transport == TransportKind.wireless
              ? 'Start an FTP-server app on your phone, then tap the Wi-Fi '
                  'button above and enter the address it shows. Both devices '
                  'must be on the same network.'
              : 'Connect your phone over USB, then set its USB mode to '
                  '“File Transfer / MTP” (swipe down → tap the USB notification). '
                  'No Developer Options needed.',
        ),
      );
    }

    final device = state.selected;
    if (device == null) {
      return const _CenteredMessage(
        icon: Icons.smartphone,
        title: 'Select a device',
        message: 'Choose a device from the menu above.',
      );
    }

    if (!device.isReady) {
      final g = _guidanceFor(device);
      return _CenteredMessage(
        icon: g.icon,
        color: Theme.of(context).colorScheme.error,
        title: g.title,
        message: g.message,
      );
    }

    return BlocBuilder<TransportCubit, TransportKind>(
      builder: (context, transport) => PhoneBrowser(
        bridge: const PlatformBridge(),
        serial: device.serial,
        deviceName: device.displayName,
        transport: transport,
      ),
    );
  }

  ({IconData icon, String title, String message}) _guidanceFor(Device d) {
    return (
      icon: Icons.help_outline,
      title: 'Device not ready',
      message: 'Reported state: ${d.state}.',
    );
  }
}

class _DeviceBar extends StatelessWidget {
  const _DeviceBar();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DeviceCubit, DeviceState>(
      builder: (context, state) {
        return Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              const _TransportToggle(),
              const SizedBox(width: 12),
              const Icon(Icons.smartphone, size: 18),
              const SizedBox(width: 8),
              const Text('Device:', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              if (state.devices.isEmpty)
                const Text('none', style: TextStyle(color: Colors.grey))
              else
                DropdownButton<String>(
                  value: state.selectedSerial,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final d in state.devices)
                      DropdownMenuItem(
                        value: d.serial,
                        child: _DeviceMenuItem(device: d),
                      ),
                  ],
                  onChanged: (serial) {
                    if (serial != null) {
                      context.read<DeviceCubit>().select(serial);
                    }
                  },
                ),
              const Spacer(),
              const _ModeToggle(),
              const SizedBox(width: 8),
              IconButton(
                iconSize: 18,
                tooltip: 'Connect over Wi-Fi',
                onPressed: () {
                  final transport = context.read<TransportCubit>();
                  showDialog(
                    context: context,
                    builder: (_) => WirelessDialog(
                      bridge: const PlatformBridge(),
                      transport: transport,
                    ),
                  );
                },
                icon: const Icon(Icons.wifi),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Transport selector (MTP ↔ Wireless). Switching re-points device discovery
/// and browse/transfer routing between the USB (native) and Wi-Fi (FTP) paths.
class _TransportToggle extends StatelessWidget {
  const _TransportToggle();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TransportCubit, TransportKind>(
      builder: (context, transport) {
        return SegmentedButton<TransportKind>(
          showSelectedIcon: false,
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            textStyle:
                WidgetStatePropertyAll(Theme.of(context).textTheme.labelSmall),
          ),
          segments: const [
            ButtonSegment(
                value: TransportKind.mtp,
                label: Text('MTP'),
                icon: Icon(Icons.usb, size: 14)),
            ButtonSegment(
                value: TransportKind.wireless,
                label: Text('Wireless'),
                icon: Icon(Icons.wifi, size: 14)),
          ],
          selected: {transport},
          onSelectionChanged: (sel) =>
              context.read<TransportCubit>().setTransport(sel.first),
        );
      },
    );
  }
}

/// Minimal Queue/Parallel selector, reflecting the persisted preference.
class _ModeToggle extends StatelessWidget {
  const _ModeToggle();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TransferCubit, TransferQueueState>(
      builder: (context, state) {
        return SegmentedButton<TransferMode>(
          showSelectedIcon: false,
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            textStyle: WidgetStatePropertyAll(
                Theme.of(context).textTheme.labelSmall),
          ),
          segments: const [
            ButtonSegment(
                value: TransferMode.queue,
                label: Text('Queue'),
                icon: Icon(Icons.list, size: 14)),
            ButtonSegment(
                value: TransferMode.parallel,
                label: Text('Parallel'),
                icon: Icon(Icons.dynamic_feed, size: 14)),
          ],
          selected: {state.mode},
          onSelectionChanged: (sel) =>
              context.read<TransferCubit>().setMode(sel.first),
        );
      },
    );
  }
}

class _DeviceMenuItem extends StatelessWidget {
  final Device device;
  const _DeviceMenuItem({required this.device});

  @override
  Widget build(BuildContext context) {
    final color = device.isReady ? Colors.green : Colors.orange;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(device.displayName),
        const SizedBox(width: 8),
        Text('(${device.state})',
            style: const TextStyle(color: Colors.grey, fontSize: 12)),
      ],
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final String title;
  final String message;

  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: color),
              const SizedBox(height: 16),
              Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Text(message,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}
