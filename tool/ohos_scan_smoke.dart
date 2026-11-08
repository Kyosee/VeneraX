import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: ScanProbe()));
}

class ScanProbe extends StatefulWidget {
  const ScanProbe({super.key});

  @override
  State<ScanProbe> createState() => _ScanProbeState();
}

class _ScanProbeState extends State<ScanProbe> {
  String status = 'Ready';
  bool busy = false;

  Future<void> scan() async {
    setState(() => busy = true);
    try {
      final value = await const MethodChannel(
        'venera/scan',
      ).invokeMethod<String>('scan');
      status = value == null
          ? 'PASS: system scanner cancelled'
          : 'PASS: scanner returned ${value.length} characters';
    } catch (error) {
      status = 'FAIL: $error';
    }
    debugPrint('SCAN: $status');
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('System scan probe')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          ElevatedButton(
            onPressed: busy ? null : scan,
            child: const Text('Scan a test QR code'),
          ),
          Text(status),
        ],
      ),
    ),
  );
}
