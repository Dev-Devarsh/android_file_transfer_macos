import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../cubit/ftp_server_cubit.dart';

/// Flutter UI for the Android companion. Native code only runs the FTP server;
/// this page starts/stops it and shows live address + activity log.
class AndroidFtpPage extends StatefulWidget {
  const AndroidFtpPage({super.key});

  @override
  State<AndroidFtpPage> createState() => _AndroidFtpPageState();
}

class _AndroidFtpPageState extends State<AndroidFtpPage> {
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _pass;
  final _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _port = TextEditingController(text: '2121');
    _user = TextEditingController(text: 'anonymous');
    _pass = TextEditingController();
  }

  @override
  void dispose() {
    _port.dispose();
    _user.dispose();
    _pass.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  void _syncFields(FtpServerState state) {
    if (state.running) return;
    final portText = state.port.toString();
    if (_port.text != portText && _port.text == '2121') {
      _port.text = portText;
    }
    if (_user.text == 'anonymous' &&
        state.user.isNotEmpty &&
        _user.text != state.user) {
      _user.text = state.user;
    }
  }

  Future<void> _toggle(FtpServerCubit cubit, FtpServerState state) async {
    if (state.running) {
      await cubit.stop();
      return;
    }
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      cubit.reportError('Enter a valid port (1–65535).');
      return;
    }
    await cubit.start(
      port: port,
      user: _user.text.trim().isEmpty ? 'anonymous' : _user.text.trim(),
      pass: _pass.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<FtpServerCubit, FtpServerState>(
      listenWhen: (prev, next) =>
          prev.error != next.error || prev.log != next.log,
      listener: (context, state) {
        _syncFields(state);
        if (state.error != null && state.error!.isNotEmpty) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(state.error!)));
        }
        if (_logScroll.hasClients) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_logScroll.hasClients) return;
            _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
          });
        }
      },
      builder: (context, state) {
        final cubit = context.read<FtpServerCubit>();
        final scheme = Theme.of(context).colorScheme;
        final ip = (state.host == null || state.host!.isEmpty)
            ? 'no Wi-Fi address'
            : state.host!;
        final address = state.running
            ? 'ftp://$ip:${state.port}  (user: ${state.user})'
            : 'ftp://$ip:${_port.text.trim().isEmpty ? state.port : _port.text.trim()}';

        return Scaffold(
          appBar: AppBar(title: const Text('AFT Wi-Fi FTP')),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Serve this phone’s files to the macOS app over Wi-Fi.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              SelectableText(
                address,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 4),
              Text(
                state.running
                    ? 'Running — connect from the Mac using the address above.'
                    : 'Stopped.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (state.rootPath.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Serving ${state.rootPath}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 20),
              TextField(
                controller: _port,
                enabled: !state.running,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _user,
                enabled: !state.running,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pass,
                enabled: !state.running,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: state.busy ? null : () => _toggle(cubit, state),
                child: state.busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(state.running ? 'Stop server' : 'Start server'),
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: state.hasStorageAccess ? null : cubit.requestStorage,
                child: Text(
                  state.hasStorageAccess
                      ? 'All-files access granted'
                      : 'Grant all-files access',
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Text(
                    'Activity log',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: cubit.clearLog,
                    child: const Text('Clear'),
                  ),
                ],
              ),
              Container(
                height: 220,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(8),
                child: state.log.isEmpty
                    ? const SizedBox.expand()
                    : SingleChildScrollView(
                        controller: _logScroll,
                        child: SelectableText(
                          state.log.join('\n'),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(fontFamily: 'monospace'),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
