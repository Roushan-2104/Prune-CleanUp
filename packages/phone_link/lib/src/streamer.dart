import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'read_only_guard.dart';

/// Reads any slice of a phone file on demand — so a 1.5 GB video can play
/// from the phone without being copied first.
///
/// - ONE long-lived connection to the phone (`adb shell -T`): no ~65 ms
///   setup cost per read.
/// - Reads in 256 KB blocks with `dd` (read-only; checked by the guard).
/// - Keeps recently read blocks in memory (never on disk) and can read
///   ahead, so playback and seeking feel instant.
class PhoneStreamer {
  PhoneStreamer(this.adbPath, this.serial, {this.cacheBytes = 96 << 20});

  final String adbPath;
  final String serial;
  final int cacheBytes;

  static const blockSize = 256 * 1024;

  Process? _shell;
  final _incoming = _ByteQueue();
  Completer<void>? _dataArrived;
  Future<void> _lane = Future.value(); // one dd at a time on the connection

  // LRU block cache: "path#block" → bytes.
  final _cache = LinkedHashMap<String, Uint8List>();
  int _cached = 0;

  /// Bytes [offset, offset+length) of [path] (whose size is [fileSize]).
  Future<Uint8List> read(String path, int fileSize, int offset, int length) async {
    if (offset >= fileSize || length <= 0) return Uint8List(0);
    final end = (offset + length).clamp(0, fileSize);
    final first = offset ~/ blockSize, last = (end - 1) ~/ blockSize;
    await _ensureBlocks(path, fileSize, first, last);

    final out = BytesBuilder(copy: false);
    for (var b = first; b <= last; b++) {
      final block = _get(path, b)!;
      final from = b == first ? offset - b * blockSize : 0;
      final to = b == last ? end - b * blockSize : block.length;
      out.add(Uint8List.sublistView(block, from, to));
    }
    return out.takeBytes();
  }

  /// Fetches [bytes] starting at [offset] in the background, so a later
  /// [read] there is served from memory.
  void readAhead(String path, int fileSize, int offset, int bytes) {
    if (offset >= fileSize) return;
    final first = offset ~/ blockSize;
    final last = ((offset + bytes).clamp(0, fileSize) - 1) ~/ blockSize;
    unawaited(_ensureBlocks(path, fileSize, first, last).catchError((_) {}));
  }

  Future<void> _ensureBlocks(String path, int fileSize, int first, int last) async {
    // Fetch each run of missing blocks with a single dd.
    var b = first;
    while (b <= last) {
      if (_get(path, b) != null) {
        b++;
        continue;
      }
      var runEnd = b;
      while (runEnd + 1 <= last && _get(path, runEnd + 1) == null && runEnd - b < 15) {
        runEnd++; // at most 16 blocks (4 MB) per request
      }
      final data = await _fetch(path, fileSize, b, runEnd - b + 1);
      for (var i = 0; i <= runEnd - b; i++) {
        final from = i * blockSize;
        if (from >= data.length) break;
        _put(path, b + i, Uint8List.sublistView(data, from, (from + blockSize).clamp(0, data.length)));
      }
      b = runEnd + 1;
    }
  }

  Future<Uint8List> _fetch(String path, int fileSize, int skip, int count) {
    final expected = ((skip + count) * blockSize).clamp(0, fileSize) - skip * blockSize;
    if (expected <= 0) return Future.value(Uint8List(0));
    // Encoded as one line of base64 on the phone: Windows' adb inserts bytes
    // into raw binary over a long-lived connection (CR before every LF).
    final command = 'dd if=${shellQuote(path)} bs=$blockSize skip=$skip count=$count status=none | base64 -w 0';
    ensureReadOnly(command);
    final textLength = 4 * ((expected + 2) ~/ 3);

    final result = _lane.then((_) async {
      final shell = await _connection();
      shell.stdin.writeln(command);
      try {
        final text = await _take(textLength).timeout(const Duration(seconds: 15));
        final bytes = base64Decode(String.fromCharCodes(text));
        if (bytes.length != expected) throw FileSystemException('Unexpected length from the phone', path);
        return bytes;
      } on TimeoutException {
        _restart(); // the phone didn't answer (file gone, cable pulled): start fresh
        throw FileSystemException('Phone did not return the requested part of the file', path);
      }
    });
    _lane = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Process> _connection() async {
    if (_shell != null) return _shell!;
    final p = await Process.start(adbPath, ['-s', serial, 'shell', '-T']);
    p.stdout.listen((chunk) {
      _incoming.add(chunk);
      _dataArrived?.complete();
      _dataArrived = null;
    }, onDone: () {
      _shell = null;
      _dataArrived?.complete();
      _dataArrived = null;
    });
    p.stderr.drain<void>();
    return _shell = p;
  }

  Future<Uint8List> _take(int n) async {
    while (_incoming.length < n) {
      if (_shell == null) throw const FileSystemException('Connection to the phone closed');
      _dataArrived = Completer<void>();
      await _dataArrived!.future;
    }
    return _incoming.take(n);
  }

  void _restart() {
    _shell?.kill();
    _shell = null;
    _incoming.clear();
  }

  Uint8List? _get(String path, int block) {
    final key = '$path#$block';
    final v = _cache.remove(key);
    if (v != null) _cache[key] = v; // mark as recently used
    return v;
  }

  void _put(String path, int block, Uint8List data) {
    final key = '$path#$block';
    final old = _cache.remove(key);
    if (old != null) _cached -= old.length;
    _cache[key] = data;
    _cached += data.length;
    while (_cached > cacheBytes && _cache.isNotEmpty) {
      final oldest = _cache.keys.first;
      _cached -= _cache.remove(oldest)!.length;
    }
  }

  Future<void> close() async {
    _shell?.stdin.writeln('exit');
    _restart();
    _cache.clear();
    _cached = 0;
  }
}

/// A FIFO of incoming bytes from which exact amounts can be taken.
class _ByteQueue {
  final _chunks = Queue<List<int>>();
  int _head = 0; // bytes already consumed from the first chunk
  int length = 0;

  void add(List<int> chunk) {
    if (chunk.isEmpty) return;
    _chunks.add(chunk);
    length += chunk.length;
  }

  Uint8List take(int n) {
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final c = _chunks.first;
      final available = c.length - _head;
      final need = n - filled;
      final k = available < need ? available : need;
      out.setRange(filled, filled + k, c, _head);
      filled += k;
      _head += k;
      if (_head == c.length) {
        _chunks.removeFirst();
        _head = 0;
      }
    }
    length -= n;
    return out;
  }

  void clear() {
    _chunks.clear();
    _head = 0;
    length = 0;
  }
}
