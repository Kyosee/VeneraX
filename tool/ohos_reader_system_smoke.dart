import 'package:flutter/material.dart';
import 'package:flutter_memory_info/flutter_memory_info.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:venera/utils/volume.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: ReaderSystemProbe()));
}

class ReaderSystemProbe extends StatefulWidget {
  const ReaderSystemProbe({super.key});

  @override
  State<ReaderSystemProbe> createState() => _ReaderSystemProbeState();
}

class _ReaderSystemProbeState extends State<ReaderSystemProbe> {
  late final listener = VolumeListener(
    onUp: () => report(up: true),
    onDown: () => report(up: false),
  );
  int up = 0;
  int down = 0;
  bool listening = false;
  String memory = 'Checking memory...';
  String browser = '';

  @override
  void initState() {
    super.initState();
    checkMemory();
  }

  Future<void> checkMemory() async {
    try {
      final bytes = await MemoryInfo.getFreePhysicalMemorySize();
      if (bytes == null || bytes <= 0) throw StateError('Invalid memory value');
      memory = 'PASS: available memory $bytes bytes';
    } catch (error) {
      memory = 'FAIL: memory $error';
    }
    debugPrint(memory);
    if (mounted) setState(() {});
  }

  void report({required bool up}) {
    if (!mounted) return;
    setState(() {
      if (up) {
        this.up++;
      } else {
        down++;
      }
    });
    debugPrint('VOLUME: up=${this.up}, down=$down, listening=$listening');
  }

  void toggle() {
    if (listening) {
      listener.cancel();
    } else {
      listener.listen();
    }
    setState(() => listening = !listening);
    debugPrint('VOLUME: listening=$listening');
  }

  Future<void> openBrowser() async {
    try {
      final opened = await launchUrl(
        Uri.parse('https://example.com'),
        mode: LaunchMode.externalApplication,
      );
      browser = opened
          ? 'PASS: browser launch accepted'
          : 'FAIL: browser launch';
    } catch (error) {
      browser = 'FAIL: browser $error';
    }
    debugPrint(browser);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    listener.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Reader system probe')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(memory),
        Text('Volume up: $up; down: $down; listening: $listening'),
        ElevatedButton(
          onPressed: toggle,
          child: Text(
            listening ? 'Stop volume listener' : 'Listen for volume keys',
          ),
        ),
        ElevatedButton(
          onPressed: openBrowser,
          child: const Text('Open example.com in system browser'),
        ),
        Text(browser),
      ],
    ),
  );
}
