import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String result;
  try {
    final battery = Battery();
    final level = await battery.batteryLevel;
    final state = await battery.onBatteryStateChanged.first.timeout(
      const Duration(seconds: 10),
    );
    final powerSaving = await battery.isInBatterySaveMode;
    final network = await Connectivity().checkConnectivity();
    final networkEvent = await Connectivity().onConnectivityChanged.first
        .timeout(const Duration(seconds: 10));
    const system = MethodChannel('venera/method_channel');
    await system.invokeMethod('setScreenOn', true);
    await system.invokeMethod('setScreenOn', false);
    final proxy = await system.invokeMethod<String>('getProxy');
    final auth = LocalAuthentication();
    final supported = await auth.isDeviceSupported();
    final biometrics = await auth.getAvailableBiometrics();
    await auth.stopAuthentication();
    result =
        'PASS: battery $level/$state, power saving $powerSaving; '
        'network $network/$networkEvent; screen wake; proxy $proxy; '
        'authentication supported $supported, biometrics $biometrics.';
  } catch (error, stack) {
    result = 'FAIL: $error\n$stack';
  }
  debugPrint(result);
  runApp(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(result),
          ),
        ),
      ),
    ),
  );
}
