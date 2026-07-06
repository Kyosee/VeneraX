import 'dart:async';
import 'dart:io';

import 'package:dio/io.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/proxy.dart';
import 'package:venera/utils/ext.dart';

class FileDownloader {
  final String url;
  final String savePath;
  final int maxConcurrent;

  FileDownloader(this.url, this.savePath, {this.maxConcurrent = 4});

  int _currentBytes = 0;

  int _lastBytes = 0;

  int _fileSize = 0;

  /// Whether the server supports HTTP range requests for this URL. When false
  /// the file is fetched in a single sequential stream instead of parallel
  /// blocks (B9: avoids corrupting non-range servers / silently "succeeding"
  /// with an empty file when the size is unknown).
  bool _useRanges = true;

  /// A bare [Dio], intentionally NOT [AppDio]: this is a low-level streaming /
  /// byte-range downloader that installs its own proxy-aware client adapter
  /// (see [_download]) and must bypass the shared cache / Cloudflare / cookie /
  /// log interceptors, which would buffer or corrupt large ranged downloads.
  final _dio = Dio();

  RandomAccessFile? _file;

  bool _isWriting = false;

  int _kChunkSize = 16 * 1024 * 1024;

  bool _canceled = false;

  List<_DownloadBlock> _blocks = [];

  DateTime? _lastStatusWriteAt;

  /// Persist block progress for resume. Throttled to ~1s (force on completion)
  /// so a large download doesn't rewrite the status file on every 16KB flush
  /// (#5).
  Future<void> _writeStatus({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _lastStatusWriteAt != null &&
        now.difference(_lastStatusWriteAt!) < const Duration(seconds: 1)) {
      return;
    }
    _lastStatusWriteAt = now;
    var file = File("$savePath.download");
    await file.writeAsString(_blocks.map((e) => e.toString()).join("\n"));
  }

  /// Parse the resume status file. Returns false (and removes the file) when
  /// it is truncated/corrupt or no longer covers [_fileSize], so the caller
  /// restarts with fresh blocks instead of failing the download or resuming
  /// against a mismatched file.
  Future<bool> _readStatus() async {
    var file = File("$savePath.download");
    if (!await file.exists()) {
      return false;
    }
    try {
      var lines = await file.readAsLines();
      var blocks = lines.map((e) => _DownloadBlock.fromString(e)).toList();
      var valid = blocks.isNotEmpty &&
          blocks.first.start == 0 &&
          blocks.last.end == _fileSize;
      for (var i = 0; valid && i < blocks.length; i++) {
        var b = blocks[i];
        valid = b.start < b.end &&
            b.downloadedBytes >= 0 &&
            b.downloadedBytes <= b.end - b.start &&
            (i == 0 || blocks[i - 1].end == b.start);
      }
      if (!valid) {
        throw const FormatException("invalid resume status");
      }
      _blocks = blocks;
      return true;
    } catch (_) {
      // A truncated status file (kill mid-write) used to throw out of
      // int.parse and fail the whole resume with an error.
      try {
        await file.delete();
      } catch (_) {}
      _blocks = [];
      return false;
    }
  }

  /// create file and write empty bytes
  Future<void> _prepareFile() async {
    var file = File(savePath);
    if (await file.exists()) {
      if (file.lengthSync() == _fileSize &&
          File("$savePath.download").existsSync()) {
        _file = await file.open(mode: FileMode.append);
        return;
      } else {
        await file.delete();
      }
    }

    await file.create(recursive: true);
    _file = await file.open(mode: FileMode.append);
    await _file!.truncate(_fileSize);
  }

  Future<void> _createTasks() async {
    _fileSize = 0;
    var ranged = false;
    try {
      var res = await _dio.head(url);
      var length = res.headers["content-length"]?.first;
      _fileSize = length == null ? 0 : (int.tryParse(length) ?? 0);
      var acceptRanges = res.headers["accept-ranges"]?.first;
      ranged = acceptRanges?.toLowerCase() == "bytes";
    } catch (_) {
      // HEAD not supported by the server; fall back to a single stream below.
    }

    // Need both a known size and explicit range support to split into blocks.
    // Otherwise download sequentially (handled by _download).
    _useRanges = _fileSize > 0 && ranged;
    if (!_useRanges) {
      return;
    }

    await _prepareFile();

    if (await _readStatus()) {
      _currentBytes = _blocks.fold<int>(0,
          (previousValue, element) => previousValue + element.downloadedBytes);
    } else {
      if (_fileSize > 1024 * 1024 * 1024) {
        _kChunkSize = 64 * 1024 * 1024;
      } else if (_fileSize > 512 * 1024 * 1024) {
        _kChunkSize = 32 * 1024 * 1024;
      }

      _blocks = [];
      for (var i = 0; i < _fileSize; i += _kChunkSize) {
        var end = i + _kChunkSize;
        if (end > _fileSize) {
          _blocks.add(_DownloadBlock(i, _fileSize, 0, false));
        } else {
          _blocks.add(_DownloadBlock(i, i + _kChunkSize, 0, false));
        }
      }
    }
  }

  Stream<DownloadingStatus> start() {
    var stream = StreamController<DownloadingStatus>();
    _download(stream);
    return stream.stream;
  }

  void _reportStatus(StreamController<DownloadingStatus> stream) {
    stream.add(DownloadingStatus(_currentBytes, _fileSize, 0));
  }

  void _download(StreamController<DownloadingStatus> resultStream) async {
    try {
      var proxy = await getProxy();
      _dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          return HttpClient()
            ..findProxy = (uri) => proxy == null ? "DIRECT" : "PROXY $proxy";
        },
      );

      // determine file size + range support
      await _createTasks();

      if (_canceled) return;

      // Range path: the file may already be fully downloaded (resume).
      if (_useRanges && _file != null && _currentBytes >= _fileSize) {
        await _file!.close();
        _file = null;
        resultStream.add(DownloadingStatus(_currentBytes, _fileSize, 0, true));
        resultStream.close();
        return;
      }

      _reportStatus(resultStream);

      var timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_canceled || (_fileSize > 0 && _currentBytes >= _fileSize)) {
          timer.cancel();
          return;
        }
        resultStream.add(DownloadingStatus(
            _currentBytes, _fileSize, _currentBytes - _lastBytes));
        _lastBytes = _currentBytes;
      });

      // download the body
      if (_useRanges) {
        await _scheduleDownload();
      } else {
        await _downloadSingleStreamBody();
      }
      timer.cancel();

      if (_canceled) {
        resultStream.close();
        return;
      }
      await _file?.close();
      _file = null;
      try {
        await File("$savePath.download").delete();
      } catch (_) {}

      // For a known size, verify completeness; an unknown size trusts the
      // stream's natural end.
      if (_fileSize > 0 && _currentBytes < _fileSize) {
        resultStream
            .addError(Exception("Download failed: Expected $_fileSize bytes, "
                "but only $_currentBytes bytes downloaded."));
        resultStream.close();
        return;
      }
      if (_fileSize == 0) {
        _fileSize = _currentBytes;
      }

      resultStream.add(DownloadingStatus(_currentBytes, _fileSize, 0, true));
      resultStream.close();
    } catch (e, s) {
      await _file?.close();
      _file = null;
      resultStream.addError(e, s);
      resultStream.close();
    }
  }

  Future<void> _scheduleDownload() async {
    var tasks = <Future>[];
    while (true) {
      if (_canceled) return;
      if (tasks.length >= maxConcurrent) {
        await Future.any(tasks);
      }
      final block = _blocks.firstWhereOrNull((element) =>
          !element.downloading &&
          element.end - element.start > element.downloadedBytes);
      if (block == null) {
        break;
      }
      block.downloading = true;
      var task = _fetchBlock(block);
      task.then((value) => tasks.remove(task), onError: (e) {
        if(_canceled) return;
        throw e;
      });
      tasks.add(task);
    }
    await Future.wait(tasks);
  }

  Future<void> _fetchBlock(_DownloadBlock block) async {
    final start = block.start;
    final end = block.end;

    if (start > _fileSize) {
      return;
    }

    var options = Options(
      responseType: ResponseType.stream,
      headers: {
        "Range": "bytes=${start + block.downloadedBytes}-${end - 1}",
        "Accept": "*/*",
        "Accept-Encoding": "deflate, gzip",
      },
      preserveHeaderCase: true,
    );
    var res = await _dio.get<ResponseBody>(url, options: options);
    if (_canceled) return;
    if (res.data == null) {
      throw Exception("Failed to block $start-$end");
    }
    // If the server ignored the Range header (200 OK with the full body) while
    // we are writing multiple blocks at different offsets, the file would be
    // corrupted. Bail out clearly instead (B9).
    if (res.statusCode == 200 && _blocks.length > 1) {
      throw Exception("Server ignored range request (got 200): $url");
    }

    var buffer = <int>[];
    await for (var data in res.data!.stream) {
      if (_canceled) return;
      buffer.addAll(data);
      if (buffer.length > 16 * 1024) {
        // Overlap network reads with the other block's write while the buffer
        // is small; once it grows large, apply back-pressure instead of letting
        // it balloon (#5).
        if (_isWriting && buffer.length < 8 * 1024 * 1024) {
          continue;
        }
        while (_isWriting) {
          if (_canceled) return;
          await Future.delayed(const Duration(milliseconds: 5));
        }
        _isWriting = true;
        _currentBytes += buffer.length;
        await _file!.setPosition(start + block.downloadedBytes);
        await _file!.writeFrom(buffer);
        block.downloadedBytes += buffer.length;
        buffer.clear();
        await _writeStatus();
        _isWriting = false;
      }
    }

    if (buffer.isNotEmpty) {
      while (_isWriting) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
      _isWriting = true;
      _currentBytes += buffer.length;
      await _file!.setPosition(start + block.downloadedBytes);
      await _file!.writeFrom(buffer);
      block.downloadedBytes += buffer.length;
      await _writeStatus(force: true);
      _isWriting = false;
    }

    block.downloading = false;
  }

  /// Sequentially fetch the whole file in a single stream — used when the
  /// server doesn't support range requests (B9).
  Future<void> _downloadSingleStreamBody() async {
    var file = File(savePath);
    if (await file.exists()) {
      await file.delete();
    }
    await file.create(recursive: true);
    _file = await file.open(mode: FileMode.write);

    var res = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: {"Accept": "*/*"},
      ),
    );
    if (res.data == null) {
      throw Exception("Failed to download $url");
    }
    if (_fileSize == 0) {
      var len = res.headers.value("content-length");
      _fileSize = len == null ? 0 : (int.tryParse(len) ?? 0);
    }
    await for (var data in res.data!.stream) {
      if (_canceled) return;
      await _file!.writeFrom(data);
      _currentBytes += data.length;
    }
  }

  Future<void> stop() async {
    _canceled = true;
    await _file?.close();
    _file = null;
  }
}

class DownloadingStatus {
  /// The current downloaded bytes
  final int downloadedBytes;

  /// The total bytes of the file
  final int totalBytes;

  /// Whether the download is finished
  final bool isFinished;

  /// The download speed in bytes per second
  final int bytesPerSecond;

  const DownloadingStatus(
      this.downloadedBytes, this.totalBytes, this.bytesPerSecond,
      [this.isFinished = false]);

  @override
  String toString() {
    return "Downloaded: $downloadedBytes/$totalBytes ${isFinished ? "Finished" : ""}";
  }
}

class _DownloadBlock {
  final int start;
  final int end;
  int downloadedBytes;
  bool downloading;

  _DownloadBlock(this.start, this.end, this.downloadedBytes, this.downloading);

  @override
  String toString() {
    return "$start-$end-$downloadedBytes";
  }

  _DownloadBlock.fromString(String str)
      : start = int.parse(str.split("-")[0]),
        end = int.parse(str.split("-")[1]),
        downloadedBytes = int.parse(str.split("-")[2]),
        downloading = false;
}
