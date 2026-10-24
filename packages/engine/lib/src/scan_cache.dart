import 'dart:convert';
import 'dart:io';

/// What we measured about one gallery item.
///
/// We store raw measurements (OCR text, sharpness, fingerprint) — not final
/// verdicts — so when the rules improve, old photos are re-judged instantly
/// without being scanned again.
class Analysis {
  const Analysis({
    required this.modified,
    required this.bytes,
    required this.takenAtMs,
    required this.screenshot,
    this.text,
    this.dHash,
    this.sharpness,
    this.entropy,
    this.faceCount,
    this.landscape,
  });

  /// The photo's "last modified" time. If it changes, we analyse again.
  final int modified;
  final int bytes;
  final int takenAtMs;
  final bool screenshot;

  /// OCR text (screenshots only).
  final String? text;

  // Camera photos only:
  final int? dHash;
  final double? sharpness;
  final double? entropy;

  /// Null until face detection has been run (only done for blur candidates).
  final int? faceCount;

  /// Wider than tall (similar photos are only compared within one orientation).
  final bool? landscape;

  Analysis withFaceCount(int count) => Analysis(
        modified: modified, bytes: bytes, takenAtMs: takenAtMs, screenshot: screenshot,
        text: text, dHash: dHash, sharpness: sharpness, entropy: entropy, faceCount: count, landscape: landscape,
      );

  Map<String, Object?> toJson() => {
        'm': modified, 'b': bytes, 't': takenAtMs, 's': screenshot,
        if (text != null) 'x': text,
        if (dHash != null) 'h': dHash,
        if (sharpness != null) 'p': sharpness,
        if (entropy != null) 'e': entropy,
        if (faceCount != null) 'f': faceCount,
        if (landscape != null) 'l': landscape,
      };

  factory Analysis.fromJson(Map<String, dynamic> j) => Analysis(
        modified: j['m'] as int,
        bytes: j['b'] as int,
        takenAtMs: j['t'] as int,
        screenshot: j['s'] as bool,
        text: j['x'] as String?,
        dHash: j['h'] as int?,
        sharpness: (j['p'] as num?)?.toDouble(),
        entropy: (j['e'] as num?)?.toDouble(),
        faceCount: j['f'] as int?,
        landscape: j['l'] as bool?,
      );
}

/// The app's private memory of already-analysed photos, kept in one JSON file
/// inside the app's own storage (never uploaded, removed if the app is uninstalled).
class ScanCache {
  ScanCache(this.file, [Map<String, Analysis>? entries]) : entries = entries ?? {};

  /// Bump when *what we measure* changes (not when rules/thresholds change),
  /// so stale measurements are thrown away and everything is re-scanned once.
  static const formatVersion = 1;

  final File file;
  final Map<String, Analysis> entries;

  static Future<ScanCache> load(File file) async {
    try {
      if (!await file.exists()) return ScanCache(file);
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (json['v'] != formatVersion) return ScanCache(file);
      final raw = json['items'] as Map<String, dynamic>;
      return ScanCache(file, {
        for (final MapEntry(:key, :value) in raw.entries)
          key: Analysis.fromJson(value as Map<String, dynamic>),
      });
    } catch (_) {
      // A corrupt file just means one full re-scan — never a crash.
      return ScanCache(file);
    }
  }

  /// Fresh entry for [id] if the photo hasn't changed since we analysed it.
  Analysis? lookup(String id, int modified) {
    final e = entries[id];
    return e != null && e.modified == modified ? e : null;
  }

  /// Forget photos that are no longer in the gallery.
  void retainOnly(Set<String> ids) => entries.removeWhere((id, _) => !ids.contains(id));

  /// Writes to a temp file first, then swaps it in, so a crash mid-save
  /// can't leave a half-written file.
  Future<void> save() async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'v': formatVersion,
      'items': {for (final MapEntry(:key, :value) in entries.entries) key: value.toJson()},
    }));
    await tmp.rename(file.path);
  }
}
