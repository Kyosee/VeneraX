import 'dart:io';

import 'package:file_selector/file_selector.dart' as selector;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  runApp(const MaterialApp(home: FileProbe()));
}

class FileProbe extends StatefulWidget {
  const FileProbe({super.key});

  @override
  State<FileProbe> createState() => _FileProbeState();
}

class _FileProbeState extends State<FileProbe> {
  String status = 'Ready';
  bool busy = false;
  final bytes = Uint8List.fromList(
    List.generate(600003, (index) => index % 251),
  );

  Future<void> run(Future<String> Function() operation) async {
    setState(() {
      busy = true;
      status = 'Running';
    });
    try {
      status = 'PASS: ${await operation()}';
    } catch (error, stack) {
      status = 'FAIL: $error\n$stack';
    }
    debugPrint(status);
    if (mounted) setState(() => busy = false);
  }

  Future<File> fixture() async {
    final cache = await getTemporaryDirectory();
    return File('${cache.path}/鸿蒙文件测试.txt').writeAsBytes(bytes, flush: true);
  }

  Future<String> roundTrip() async {
    final source = await fixture();
    final saved = await FlutterFileDialog.saveFile(
      params: SaveFileDialogParams(sourceFilePath: source.path),
    );
    if (saved == null) throw StateError('Save was cancelled.');
    debugPrint('File probe saved: $saved');
    final picked = await selector.openFile(
      acceptedTypeGroups: [
        const selector.XTypeGroup(label: 'Text', extensions: ['txt']),
      ],
    );
    if (picked == null) throw StateError('Pick was cancelled.');
    if (!listEquals(await picked.readAsBytes(), bytes)) {
      throw StateError('Saved and imported bytes differ.');
    }
    if (!listEquals(await source.readAsBytes(), bytes)) {
      throw StateError('Source was modified.');
    }
    return 'file export/import, 600003 bytes, Unicode name, source preserved';
  }

  Future<String> cancelPick() async {
    if (await selector.openFile() != null) {
      throw StateError('Expected picker cancellation.');
    }
    return 'picker cancellation';
  }

  Future<String> cancelSave() async {
    final source = await fixture();
    if (await FlutterFileDialog.saveFile(
          params: SaveFileDialogParams(sourceFilePath: source.path),
        ) !=
        null) {
      throw StateError('Expected save cancellation.');
    }
    if (!listEquals(await source.readAsBytes(), bytes)) {
      throw StateError('Source was modified.');
    }
    return 'save cancellation preserves source';
  }

  Future<String> share() async {
    final source = await fixture();
    final result = await SharePlus.instance.share(
      ShareParams(files: [XFile(source.path, mimeType: 'text/plain')]),
    );
    if (result.status == ShareResultStatus.success) {
      throw StateError('Expected dismissal without choosing a recipient.');
    }
    if (!listEquals(await source.readAsBytes(), bytes)) {
      throw StateError('Source was modified.');
    }
    return 'share sheet dismissal, status ${result.status}, source preserved';
  }

  Future<String> boundary() async {
    const channel = MethodChannel('flutter_file_dialog');
    for (final path in [
      '/system/etc/hosts',
      '${(await getTemporaryDirectory()).path}/../files/test',
    ]) {
      try {
        await channel.invokeMethod<String>('saveFile', {
          'sourceFilePath': path,
        });
        throw StateError('Unsafe source accepted: $path');
      } on PlatformException catch (error) {
        if (error.code != 'FILE_SAVE_FAILED') rethrow;
      }
    }
    return 'outside-sandbox and traversal sources rejected';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('HarmonyOS file probe')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        for (final item in <(String, Future<String> Function())>[
          ('Export then import', roundTrip),
          ('Cancel file picker', cancelPick),
          ('Cancel save picker', cancelSave),
          ('Open and dismiss share', share),
          ('Reject unsafe source', boundary),
        ])
          ElevatedButton(
            onPressed: busy ? null : () => run(item.$2),
            child: Text(item.$1),
          ),
        const SizedBox(height: 24),
        SelectableText(status),
      ],
    ),
  );
}
