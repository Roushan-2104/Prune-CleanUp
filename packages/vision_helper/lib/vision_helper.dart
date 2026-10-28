/// Text reading (OCR) and face counting using the engines built into Windows,
/// via PruneVision.exe. Everything runs locally.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class VisionError implements Exception {
  VisionError(this.message);
  final String message;
  @override
  String toString() => 'VisionError: $message';
}

/// What Windows found in one image.
class VisionResult {
  const VisionResult({required this.path, this.text, this.faces, this.gray, this.thumb, this.error});

  final String path;

  /// Text lines joined with "\n"; null if text wasn't requested or failed.
  final String? text;

  /// Number of faces; null if faces weren't requested or failed.
  final int? faces;

  /// A small grayscale copy (longest side 256 px), if requested.
  final SmallGray? gray;

  /// A picture of what the file is (PNG): a PDF's first page, an app's
  /// icon, or the thumbnail or type icon Windows shows for it.
  final Uint8List? thumb;

  /// Why this image couldn't be read (unreadable file, unsupported format…).
  final String? error;

  bool get ok => error == null;
}

/// One byte per pixel, row by row, longest side at most 256.
class SmallGray {
  const SmallGray(this.width, this.height, this.pixels);
  final int width;
  final int height;
  final Uint8List pixels;
}

/// What to do with one image.
class VisionJob {
  const VisionJob(this.path,
      {this.text = false, this.textMaxSide, this.faces = false, this.gray = false, this.thumb = false});
  final String path;
  final bool text;

  /// Read text with the image shrunk so its longest side is at most this
  /// (null: full size). Text reading costs grow with the pixel count.
  final int? textMaxSide;
  final bool faces;
  final bool gray;
  final bool thumb;

  String get jobs => [
        if (text) textMaxSide == null ? 'ocr' : 'ocr@$textMaxSide',
        if (faces) 'faces',
        if (gray) 'gray',
        if (thumb) 'thumb',
      ].join(',');
}

/// What this PC's Windows can do.
class VisionCapabilities {
  const VisionCapabilities({required this.canReadText, required this.canFindFaces, required this.textLanguage});
  final bool canReadText;
  final bool canFindFaces;
  final String textLanguage;
}

/// Runs PruneVision.exe on batches of images, several batches at once.
///
/// Requests go to the helper as a list file rather than over stdin: .NET
/// Framework programs can't reliably read the stdin pipes Dart creates.
///
/// With [keepAlive], up to [parallel] helpers stay running between batches
/// (and between calls) instead of one starting per batch; call [close] when
/// done.
class Vision {
  Vision(this.exePath, {int? parallel, this.batchSize = 40, this.keepAlive = false})
      : parallel = parallel ?? max(1, min(8, Platform.numberOfProcessors ~/ 2));

  final String exePath;
  final int parallel;
  final int batchSize;
  final bool keepAlive;

  final _idle = <_Helper>[];
  final _waiting = <Completer<_Helper>>[];
  final _all = <_Helper>{};
  int _starting = 0;
  bool _closed = false;

  /// Stops the helpers kept running by [keepAlive]. Safe to call twice.
  Future<void> close() async {
    _closed = true;
    final helpers = _all.toList();
    _all.clear();
    _idle.clear();
    for (final w in _waiting) {
      w.completeError(VisionError('closed'));
    }
    _waiting.clear();
    await Future.wait(helpers.map((h) => h.stop()));
  }

  Future<_Helper> _take() async {
    if (_closed) throw VisionError('closed');
    while (_idle.isNotEmpty) {
      final h = _idle.removeLast();
      if (h.alive) return h;
      _all.remove(h);
    }
    if (_all.length + _starting < parallel) {
      _starting++;
      try {
        final h = await _Helper.start(exePath);
        if (_closed) {
          await h.stop();
          throw VisionError('closed');
        }
        _all.add(h);
        return h;
      } finally {
        _starting--;
      }
    }
    final wait = Completer<_Helper>();
    _waiting.add(wait);
    return wait.future;
  }

  void _give(_Helper h) {
    if (_closed || !h.alive) {
      _all.remove(h);
      if (!_closed) h.stop();
      // A helper died: let the next waiter start a fresh one.
      if (_waiting.isNotEmpty && !_closed) {
        final w = _waiting.removeAt(0);
        _take().then(w.complete, onError: w.completeError);
      }
      return;
    }
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete(h);
    } else {
      _idle.add(h);
    }
  }

  Future<VisionCapabilities> capabilities() async {
    final r = await Process.run(exePath, const ['info'], stdoutEncoding: utf8);
    if (r.exitCode != 0) throw VisionError('helper failed to start: ${r.stderr}');
    final j = jsonDecode(LineSplitter.split(r.stdout as String).first) as Map<String, dynamic>;
    return VisionCapabilities(
      canReadText: j['ocr'] == true,
      canFindFaces: j['faces'] == true,
      textLanguage: j['ocrLanguage'] as String? ?? '',
    );
  }

  /// Reads text and/or counts faces in every image. Results come back in the
  /// same order as [paths]; a bad image gives a result with [VisionResult.error]
  /// instead of failing the whole run. [onProgress] reports images finished.
  Future<List<VisionResult>> analyse(List<String> paths,
      {bool text = true, bool faces = false, bool gray = false, void Function(int done)? onProgress}) {
    if (!text && !faces && !gray) throw ArgumentError('ask for text, faces or a grayscale copy');
    return analyseEach([for (final p in paths) VisionJob(p, text: text, faces: faces, gray: gray)], onProgress: onProgress);
  }

  /// Like [analyse], but each image says what it needs (e.g. text only for
  /// screenshots, a grayscale copy for every photo).
  Future<List<VisionResult>> analyseEach(List<VisionJob> all, {void Function(int done)? onProgress}) async {
    final todo = all.where((j) => j.jobs.isNotEmpty).toList();
    final batches = [
      for (var i = 0; i < todo.length; i += batchSize) todo.sublist(i, min(i + batchSize, todo.length)),
    ];
    final results = List<List<VisionResult>?>.filled(batches.length, null);
    var next = 0, done = 0;

    Future<void> worker() async {
      while (next < batches.length) {
        final index = next++;
        results[index] = await _runBatch(batches[index]);
        done += batches[index].length;
        onProgress?.call(done);
      }
    }

    await Future.wait(List.generate(min(parallel, batches.length), (_) => worker()));
    return [for (final r in results) ...r!];
  }

  Future<VisionResult> readText(String path) async => (await analyse([path])).single;
  Future<VisionResult> countFaces(String path) async => (await analyse([path], text: false, faces: true)).single;

  Future<List<VisionResult>> _runBatch(List<VisionJob> jobs) async {
    if (!keepAlive) return _runOnce(jobs);
    final helper = await _take();
    try {
      final lines = await helper.run(_listOf(jobs));
      // No reply at all means nothing was checked (as in [_runOnce]): an
      // error, so these photos stay pending instead of being saved as failed.
      if (lines.isEmpty && jobs.isNotEmpty) throw VisionError('helper stopped before checking any photo');
      return _resultsOf(jobs, lines);
    } finally {
      _give(helper);
    }
  }

  static String _listOf(List<VisionJob> jobs) => jobs.map((j) => '${j.jobs}\t${File(j.path).absolute.path}').join('\n');

  /// One reply per job, in order. If the helper died part-way, the rest
  /// are reported as failed rather than silently dropped.
  static List<VisionResult> _resultsOf(List<VisionJob> jobs, List<String> lines) => [
        for (var i = 0; i < jobs.length; i++)
          if (i < lines.length) _parse(jobs[i].path, lines[i]) else VisionResult(path: jobs[i].path, error: 'helper stopped early'),
      ];

  /// Starts a helper for just this batch.
  Future<List<VisionResult>> _runOnce(List<VisionJob> jobs) async {
    final dir = await Directory.systemTemp.createTemp('declutter_vision_');
    try {
      final list = File('${dir.path}${Platform.pathSeparator}list.txt');
      await list.writeAsString(_listOf(jobs), encoding: utf8);
      final r = await Process.run(exePath, ['ocr', list.path], stdoutEncoding: utf8, stderrEncoding: utf8);
      final lines = LineSplitter.split(r.stdout as String).skip(1).toList(); // first line = capabilities
      if (r.exitCode != 0 && lines.isEmpty) throw VisionError('helper failed: ${r.stderr}');
      return _resultsOf(jobs, lines);
    } finally {
      await dir.delete(recursive: true);
    }
  }

  static VisionResult _parse(String path, String line) {
    final j = jsonDecode(line) as Map<String, dynamic>;
    if (j['ok'] != true) return VisionResult(path: path, error: j['error'] as String? ?? 'unknown error');
    return VisionResult(
      path: path,
      text: j['text'] as String?,
      faces: j['faces'] as int?,
      gray: _gray(j['gray']),
      thumb: j['thumb'] is String ? base64Decode(j['thumb'] as String) : null,
    );
  }

  /// Unpacks the helper's grayscale image, dropping any row padding.
  static SmallGray? _gray(Object? g) {
    if (g is! Map<String, dynamic>) return null;
    final w = g['w'] as int, h = g['h'] as int, stride = g['stride'] as int;
    final raw = base64Decode(g['b64'] as String);
    if (stride == w) return SmallGray(w, h, raw);
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      out.setRange(y * w, y * w + w, raw, y * stride);
    }
    return SmallGray(w, h, out);
  }
}

/// One PruneVision.exe kept running in "serve" mode: lists go in as files
/// 1.txt, 2.txt, … in its own folder; replies come back on stdout, each
/// list's ending with `{"end":n}`.
class _Helper {
  _Helper._(this._process, this._dir) {
    _process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine, onDone: _onGone);
    _process.stderr.drain<void>();
  }

  static Future<_Helper> start(String exePath) async {
    final dir = await Directory.systemTemp.createTemp('prune_vision_');
    try {
      // Our process id lets the helper quit by itself if Prune is closed.
      return _Helper._(await Process.start(exePath, ['serve', dir.path, '$pid']), dir);
    } catch (e) {
      await dir.delete(recursive: true);
      throw VisionError('helper failed to start: $e');
    }
  }

  final Process _process;
  final Directory _dir;
  int _sent = 0;
  bool _ready = false;
  bool alive = true;
  List<String> _replies = [];
  Completer<List<String>>? _pending;

  /// The helper's reply lines to one list, one per image; fewer if it died.
  /// Throws [VisionError] if the list couldn't be handed over or read.
  Future<List<String>> run(String list) async {
    if (!alive) return const [];
    final n = _sent + 1;
    final pending = _pending = Completer<List<String>>();
    _replies = [];
    // Written under another name, then renamed: the helper never sees half a list.
    final tmp = File('${_dir.path}${Platform.pathSeparator}$n.tmp');
    try {
      await tmp.writeAsString(list, encoding: utf8);
      for (var attempt = 0;; attempt++) {
        try {
          await tmp.rename('${_dir.path}${Platform.pathSeparator}$n.txt');
          break;
        } on FileSystemException {
          // A new file may be held for a moment (e.g. by an antivirus scan).
          if (attempt >= 100) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
    } on FileSystemException catch (e) {
      // The helper is still waiting for list n, which never came. It can't
      // be reused (every later list would wait forever), so it is retired
      // and the pool starts a fresh one.
      _pending = null;
      alive = false;
      _process.kill();
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } on FileSystemException {
        // removed with the helper's folder when it stops
      }
      throw VisionError('could not hand the photo list to the helper: ${e.message}');
    }
    _sent = n;
    return pending.future;
  }

  void _onLine(String line) {
    if (!_ready && line.startsWith('{"ready"')) {
      _ready = true; // the first line says what this PC can do
      return;
    }
    if (line.startsWith('{"end":')) {
      final done = _pending;
      _pending = null;
      if (line.contains('"error"')) {
        // The helper couldn't read the list: no photo in it was checked,
        // so none of them may be recorded as unreadable.
        done?.completeError(VisionError('helper could not read its photo list'));
      } else {
        done?.complete(_replies);
      }
    } else {
      _replies.add(line);
    }
  }

  void _onGone() {
    alive = false;
    final done = _pending;
    _pending = null;
    done?.complete(_replies);
  }

  /// Asks the helper to stop, which also has it remove its folder; one that
  /// is busy with a list (or stuck) is ended after a second. The folder is
  /// removed here too, in case the helper couldn't.
  Future<void> stop() async {
    alive = false;
    try {
      File('${_dir.path}${Platform.pathSeparator}stop').writeAsStringSync('');
    } on FileSystemException {
      // the folder has gone: the helper stops by itself
    }
    await _process.exitCode.timeout(const Duration(seconds: 1), onTimeout: () {
      _process.kill();
      return _process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    });
    for (var i = 0; i < 20; i++) {
      try {
        if (_dir.existsSync()) _dir.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50)); // Windows lets go of files a moment late
      }
    }
  }
}
