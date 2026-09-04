import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'cubit/device_cubit.dart';
import 'cubit/ftp_server_cubit.dart';
import 'cubit/transfer_cubit.dart';
import 'cubit/transport_cubit.dart';
import 'services/platform_bridge.dart';
import 'ui/android_ftp_page.dart';
import 'ui/home_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FileBridgeApp());
}

class FileBridgeApp extends StatelessWidget {
  const FileBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    const bridge = PlatformBridge();
    final android = Platform.isAndroid;
    return MaterialApp(
      title: 'Android File Transfer',
      debugShowCheckedModeBanner: false,
      theme: android
          ? ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.teal,
                brightness: Brightness.dark,
              ),
              useMaterial3: true,
              brightness: Brightness.dark,
            )
          : ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
              useMaterial3: true,
            ),
      themeMode: android ? ThemeMode.dark : ThemeMode.light,
      home: _home(bridge),
    );
  }

  Widget _home(PlatformBridge bridge) {
    if (Platform.isAndroid) {
      return BlocProvider(
        create: (_) => FtpServerCubit(bridge),
        child: const AndroidFtpPage(),
      );
    }
    if (Platform.isMacOS) {
      return MultiBlocProvider(
        providers: [
          BlocProvider(create: (_) => TransportCubit(bridge)),
          BlocProvider(create: (_) => DeviceCubit(bridge)),
          BlocProvider(create: (_) => TransferCubit(bridge)),
        ],
        child: const HomeShell(),
      );
    }
    return const Scaffold(body: Center(child: Text('Unsupported platform')));
  }
}
