import 'dart:io';
import 'dart:typed_data';

// Usage: dart tool/serve_ohos_ocr_models.dart <translation_models> [port]
// This serves existing local files only. Stop the process after the probe.
const _files = {
  '/text_detector/det.onnx': 8 * 1024 * 1024,
  '/ocr_en/rec.onnx': 16 * 1024 * 1024,
  '/ocr_en/dict.txt': 64 * 1024,
};

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2) {
    stderr.writeln(
      'Usage: dart tool/serve_ohos_ocr_models.dart <translation_models> [port]',
    );
    exitCode = 64;
    return;
  }
  final port = args.length == 2 ? int.tryParse(args[1]) : 18767;
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('Port must be between 0 and 65535.');
    exitCode = 64;
    return;
  }

  try {
    final root = await Directory(args[0]).resolveSymbolicLinks();
    final prefix = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    final models = <String, Uint8List>{};
    for (final entry in _files.entries) {
      final path = await File('$root${entry.key}').resolveSymbolicLinks();
      if (!path.startsWith(prefix)) {
        throw const FormatException('A model resolves outside the model root.');
      }
      final file = File(path);
      final length = await file.length();
      if (length <= 0 || length > entry.value) {
        throw const FormatException(
          'A model is empty or exceeds its size limit.',
        );
      }
      // Keep only the three permitted byte buffers; requests never open paths.
      models[entry.key] = await file.readAsBytes();
      if (models[entry.key]!.length != length) {
        throw const FormatException('A model changed while being read.');
      }
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    server.idleTimeout = const Duration(seconds: 15);
    stdout.writeln(
      'OCR model service: http://127.0.0.1:${server.port}; '
      'three allowlisted files; no request logging. Stop with Ctrl+C.',
    );
    await for (final request in server) {
      final response = request.response;
      try {
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        response.headers.set('X-Content-Type-Options', 'nosniff');
        // Exact request targets also reject queries and encoded path variants.
        final bytes = models[request.uri.toString()];
        if (request.method != 'GET' && request.method != 'HEAD') {
          response.statusCode = HttpStatus.methodNotAllowed;
          response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        } else if (bytes == null) {
          response.statusCode = HttpStatus.notFound;
        } else {
          response.headers.contentType = ContentType.binary;
          response.contentLength = bytes.length;
          if (request.method == 'GET') response.add(bytes);
        }
        await response.close();
      } on IOException {
        // An interrupted probe must not stop the service or log request data.
      }
    }
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on IOException {
    stderr.writeln(
      'Cannot read the three model files or bind the loopback port.',
    );
    exitCode = 1;
  }
}
