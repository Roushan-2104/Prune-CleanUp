/// Text reading (OCR) and face counting using the engines built into Windows,
/// via DeclutterVision.exe. Everything runs locally.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

class VisionError implements Exception {
  VisionError(this.message);
  final String message;
  @override
  String toString() => 'VisionError: $message';
}

/// What Windows found in one image.
class VisionResult {
  const VisionResult({required this.path, this.text, this.faces, this.error});

  final String path;

  /// Text lines joined with "\n"; null if text wasn't requested or failed.
  final String? text;

  /// Number of faces; null if faces weren't requested or failed.
  final int? faces;

  /// Why this image couldn't be read (unreadable file, unsupported format…).
  final String? error;

  bool get ok => error == null;
}

/// What this PC's Windows can do.
class VisionCapabilities {
  const VisionCapabilities({required this.canReadText, required this.canFindFaces, required this.textLanguage});
  final bool canReadText;
  final bool canFindFaces;
  final String textLanguage;
}

/// Runs DeclutterVision.exe on batches of images, several batches at once.
///
/// Requests go to the helper as a list file rather than over stdin: .NET
/// Framework programs can't reliably read the stdin pipes Dart creates.
class Vision {
  Vision(this.exePath, {int? parallel, this.batchSize = 40})
      : parallel = parallel ?? max(1, min(8, Platform.numberOfProcessors ~/ 2));

  final String exePath;
  final int parallel;
  final int batchSize;

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
      {bool text = true, bool faces = false, void Function(int done)? onProgress}) async {
    if (!text && !faces) throw ArgumentError('ask for text, faces or both');
    final jobs = [if (text) 'ocr', if (faces) 'faces'].join(',');
    final batches = [
      for (var i = 0; i < paths.length; i += batchSize) paths.sublist(i, min(i + batchSize, paths.length)),
    ];
    final results = List<List<VisionResult>?>.filled(batches.length, null);
    var next = 0, done = 0;

    Future<void> worker() async {
      while (next < batches.length) {
        final index = next++;
        results[index] = await _runBatch(jobs, batches[index]);
        done += batches[index].length;
        onProgress?.call(done);
      }
    }

    await Future.wait(List.generate(min(parallel, batches.length), (_) => worker()));
    return [for (final r in results) ...r!];
  }

  Future<VisionResult> readText(String path) async => (await analyse([path])).single;
  Future<VisionResult> countFaces(String path) async => (await analyse([path], text: false, faces: true)).single;

  Future<List<VisionResult>> _runBatch(String jobs, List<String> paths) async {
    final dir = await Directory.systemTemp.createTemp('declutter_vision_');
    try {
      final list = File('${dir.path}${Platform.pathSeparator}list.txt');
      await list.writeAsString(paths.map((p) => File(p).absolute.path).join('\n'), encoding: utf8);
      final r = await Process.run(exePath, [jobs, list.path], stdoutEncoding: utf8, stderrEncoding: utf8);
      final lines = LineSplitter.split(r.stdout as String).skip(1).toList(); // first line = capabilities
      if (r.exitCode != 0 && lines.isEmpty) throw VisionError('helper failed: ${r.stderr}');

      // One reply per path, in order. If the helper died part-way, the rest
      // are reported as failed rather than silently dropped.
      return [
        for (var i = 0; i < paths.length; i++)
          if (i < lines.length) _parse(paths[i], lines[i]) else VisionResult(path: paths[i], error: 'helper stopped early'),
      ];
    } finally {
      await dir.delete(recursive: true);
    }
  }

  static VisionResult _parse(String path, String line) {
    final j = jsonDecode(line) as Map<String, dynamic>;
    if (j['ok'] != true) return VisionResult(path: path, error: j['error'] as String? ?? 'unknown error');
    return VisionResult(path: path, text: j['text'] as String?, faces: j['faces'] as int?);
  }
}
