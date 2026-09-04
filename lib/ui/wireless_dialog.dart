import 'package:flutter/material.dart';

import '../cubit/transport_cubit.dart';
import '../services/platform_bridge.dart';
import '../transport/transport.dart';

/// Connect to the phone over Wi-Fi (FTP). Run any FTP-server app on the phone
/// (e.g. "WiFi FTP Server" or primitive ftpd), start it, and enter the address
/// it shows here. No ADB, no cable, no Developer Options.
class WirelessDialog extends StatefulWidget {
  final PlatformBridge bridge;
  final TransportCubit transport;
  const WirelessDialog(
      {super.key, required this.bridge, required this.transport});

  @override
  State<WirelessDialog> createState() => _WirelessDialogState();
}

class _WirelessDialogState extends State<WirelessDialog> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '2121');
  final _user = TextEditingController(text: 'anonymous');
  final _pass = TextEditingController();
  String? _status;
  bool _ok = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ok = widget.bridge.wirelessConnected;
    _restore();
  }

  Future<void> _restore() async {
    try {
      final host = await widget.bridge.getPref('wifiHost');
      final port = await widget.bridge.getPref('wifiPort');
      final user = await widget.bridge.getPref('wifiUser');
      if (!mounted) return;
      setState(() {
        if (host is String && host.isNotEmpty) _host.text = host;
        if (port is String && port.isNotEmpty) _port.text = port;
        if (user is String && user.isNotEmpty) _user.text = user;
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 0;
    if (host.isEmpty || port <= 0) {
      setState(() => _status = 'Enter the phone’s IP address and port.');
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    // Make wireless the active transport before connecting so the device list
    // reflects the FTP connection (and USB/MTP monitoring stops).
    await widget.transport.setTransport(TransportKind.wireless);
    try {
      final ok = await widget.bridge.wirelessConnect(
        host: host,
        port: port,
        user: _user.text.trim().isEmpty ? 'anonymous' : _user.text.trim(),
        pass: _pass.text,
      );
      if (ok) {
        await widget.bridge.setPref('wifiHost', host);
        await widget.bridge.setPref('wifiPort', _port.text.trim());
        await widget.bridge.setPref('wifiUser', _user.text.trim());
      }
      if (!mounted) return;
      setState(() {
        _ok = ok;
        _status = ok
            ? 'Connected ✓ — the phone is now in the device list.'
            : 'Couldn’t connect. Check the IP/port and that the FTP server '
                'app is running on the same Wi-Fi.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _disconnect() {
    widget.bridge.wirelessDisconnect();
    setState(() {
      _ok = false;
      _status = 'Disconnected.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Connect over Wi-Fi'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'On the phone, start any FTP-server app and enter the address it '
              'shows (both devices must be on the same Wi-Fi).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _host,
                    autofocus: true,
                    decoration: const InputDecoration(
                        labelText: 'Phone IP', hintText: '192.168.1.5'),
                    onSubmitted: (_) => _busy ? null : _connect(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _port,
                    decoration: const InputDecoration(labelText: 'Port'),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _user,
                    decoration: const InputDecoration(labelText: 'Username'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _pass,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'),
                    onSubmitted: (_) => _busy ? null : _connect(),
                  ),
                ),
              ],
            ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Text(
                _status!,
                style: TextStyle(
                  color: _ok
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_ok)
          TextButton(
              onPressed: _busy ? null : _disconnect,
              child: const Text('Disconnect')),
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Close')),
        FilledButton(
          onPressed: _busy ? null : _connect,
          child: _busy
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Connect'),
        ),
      ],
    );
  }
}
