import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import 'image_metrics.dart';
import 'photo_rules.dart';
import 'scan_cache.dart';
import 'text_rules.dart';
import 'verdict.dart';

/// One gallery item the engine thinks might be junk.
class ScanItem {
  ScanItem(this.asset, this.verdict, this.bytes, {this.payment, this.match});
  final AssetEntity asset;
  final Verdict verdict;
  final int bytes;
  final PaymentInfo? payment;

  /// For duplicates / similar photos: the photo we are keeping, which this
  /// one was matched against. Shown side by side so the user can compare.
  final AssetEntity? match;

  ScanItem withVerdict(Verdict v) =>
      identical(v, verdict) ? this : ScanItem(asset, v, bytes, payment: payment, match: match);
}

class ScanProgress {
  const ScanProgress(this.done, this.toCheck, this.alreadyChecked);

  /// New/changed photos analysed so far, out of [toCheck].
  final int done;
  final int toCheck;

  /// Photos skipped because an earlier scan already analysed them.
  final int alreadyChecked;
}

/// Walks the gallery on-device and produces [ScanItem]s.
/// Nothing leaves the phone: thumbnails, OCR and face detection all run locally.
///
/// Scans are incremental: measurements are remembered in a [ScanCache], so
/// only photos that are new (or edited) since the last scan get analysed.
class Scanner {
  final _ocr = TextRecognizer(script: TextRecognitionScript.latin);
  final _faces = FaceDetector(options: FaceDetectorOptions(minFaceSize: 0.1));

  Future<bool> requestAccess() async {
    final state = await PhotoManager.requestPermissionExtend();
    return state.hasAccess;
  }

  Future<File> _cacheFile() async =>
      File('${(await getApplicationSupportDirectory()).path}/scan_cache.json');

  Future<bool> hasPreviousScan() async => (await _cacheFile()).exists();

  /// Every photo seen by the last scan, flagged or not.
  Map<String, AssetEntity> gallery = {};

  Future<List<ScanItem>> scan({void Function(ScanProgress)? onProgress}) async {
    final cache = await ScanCache.load(await _cacheFile());
    final paths = await PhotoManager.getAssetPathList(type: RequestType.image, onlyAll: true);
    if (paths.isEmpty) return [];
    final all = paths.first;
    final total = await all.assetCountAsync;

    // 1. List every photo — metadata only, takes about a second.
    final assets = <AssetEntity>[];
    const pageSize = 500;
    for (var page = 0; page * pageSize < total; page++) {
      assets.addAll(await all.getAssetListPaged(page: page, size: pageSize));
    }
    final byId = gallery = {for (final a in assets) a.id: a};
    cache.retainOnly(byId.keys.toSet());

    // 2. Analyse only photos that are new or edited since the last scan.
    bool upToDate(AssetEntity a) {
      final e = cache.lookup(a.id, a.modifiedDateSecond ?? 0);
      if (e == null) return false;
      // Analysed before we looked for screenshots outside the Screenshots folder.
      return !(e.text == null && !e.screenshot && _mightBeScreenshot(a));
    }

    final toCheck = assets.where((a) => !upToDate(a)).toList();
    final alreadyChecked = assets.length - toCheck.length;
    onProgress?.call(ScanProgress(0, toCheck.length, alreadyChecked));
    for (final (i, asset) in toCheck.indexed) {
      try {
        cache.entries[asset.id] = await _analyse(asset);
      } catch (e) {
        debugPrint('Skipping ${asset.id}: $e');
      }
      final done = i + 1;
      if (done % 10 == 0 || done == toCheck.length) {
        onProgress?.call(ScanProgress(done, toCheck.length, alreadyChecked));
      }
      // Save as we go, so an interrupted scan picks up where it stopped.
      if (done % 100 == 0) await cache.save();
    }

    // 3. Face check for blur candidates that haven't had one yet.
    for (final MapEntry(key: id, value: a) in cache.entries.entries.toList()) {
      if (a.screenshot || a.faceCount != null || a.sharpness == null) continue;
      if (classifyBlurMetrics(sharpness: a.sharpness!, entropy: a.entropy!) == null) continue;
      try {
        cache.entries[id] = a.withFaceCount(await _countFaces(byId[id]!));
      } catch (e) {
        debugPrint('Face check failed for $id: $e');
      }
    }
    await cache.save();

    return _judge(cache, byId);
  }

  /// Turns saved measurements into verdicts using the current rules.
  List<ScanItem> _judge(ScanCache cache, Map<String, AssetEntity> byId) {
    final items = <String, ScanItem>{};
    final fingerprints = <PhotoFingerprint>[];

    for (final MapEntry(key: id, value: a) in cache.entries.entries) {
      final asset = byId[id];
      if (asset == null) continue;

      if (a.screenshot) {
        final text = a.text ?? '';
        var verdict = classifyScreenshotText(text);
        if (!_isScreenshot(asset)) {
          verdict = Verdict(verdict.category, verdict.confidence,
              ['Screenshot saved or received from another app', ...verdict.reasons],
              label: verdict.label);
        }
        items[id] = ScanItem(asset, verdict, a.bytes,
            payment: verdict.category == JunkCategory.paymentScreenshot ? extractPaymentInfo(text) : null);
        continue;
      }
      if (a.dHash == null || a.sharpness == null || a.entropy == null) continue;

      fingerprints.add(PhotoFingerprint(
        id: id,
        takenAt: DateTime.fromMillisecondsSinceEpoch(a.takenAtMs),
        dHash: a.dHash!,
        sharpness: a.sharpness!,
        bytes: a.bytes,
        // Same dimensions + same byte size + same look = same file.
        contentHash: '${asset.width}x${asset.height}:${a.bytes}:${a.dHash}',
        entropy: a.entropy!,
        landscape: asset.orientatedWidth > asset.orientatedHeight,
      ));

      // Face check missing (it failed)? Assume people are in it — never "sure".
      final blur = classifyBlurMetrics(
          sharpness: a.sharpness!, entropy: a.entropy!, faceCount: a.faceCount ?? 1);
      if (blur != null) items[id] = ScanItem(asset, blur, a.bytes);
    }

    // Duplicates win over blur: "keep the best copy" is easier to trust.
    for (final group in findDuplicates(fingerprints)) {
      for (final MapEntry(key: fp, value: verdict) in group.others.entries) {
        items[fp.id] = ScanItem(byId[fp.id]!, verdict, fp.bytes, match: byId[group.keep.id]);
      }
    }
    return items.values.toList();
  }

  Future<Analysis> _analyse(AssetEntity asset) async {
    final file = await asset.file;
    if (file == null) throw StateError('file not available');
    final bytes = await file.length();
    final modified = asset.modifiedDateSecond ?? 0;
    final takenAtMs = asset.createDateTime.millisecondsSinceEpoch;

    if (_isScreenshot(asset)) {
      final text = (await _ocr.processImage(InputImage.fromFilePath(file.path))).text;
      return Analysis(modified: modified, bytes: bytes, takenAtMs: takenAtMs, screenshot: true, text: text);
    }

    final thumbBytes = await asset.thumbnailDataWithSize(const ThumbnailSize(256, 256));
    if (thumbBytes == null) throw StateError('no thumbnail');
    final gray = await compute(decodeGray, thumbBytes);
    if (gray == null) throw StateError('could not decode thumbnail');

    // Text is stored even when it turns out not to be a screenshot, so this
    // photo is never read twice.
    final text = _mightBeScreenshot(asset)
        ? (await _ocr.processImage(InputImage.fromFilePath(file.path))).text
        : null;
    return Analysis(
      modified: modified, bytes: bytes, takenAtMs: takenAtMs,
      screenshot: text != null && _looksLikeScreenshot(asset, text),
      text: text,
      dHash: dHash(gray), sharpness: bestTileSharpness(gray), entropy: entropy(gray),
    );
  }

  Future<int> _countFaces(AssetEntity asset) async {
    final file = await asset.file;
    if (file == null) throw StateError('file not available');
    return (await _faces.processImage(InputImage.fromFilePath(file.path))).length;
  }

  /// Taken with this phone's screenshot button.
  bool _isScreenshot(AssetEntity a) {
    final path = (a.relativePath ?? '').toLowerCase();
    final name = (a.title ?? '').toLowerCase();
    return path.contains('screenshot') || name.startsWith('screenshot');
  }

  /// Could be a screenshot that arrived another way — received on WhatsApp,
  /// saved from Instagram, downloaded. Worth reading its text to decide.
  bool _mightBeScreenshot(AssetEntity a) {
    final path = (a.relativePath ?? '').toLowerCase();
    if (path.contains('dcim/camera')) return false;
    return _isPhoneScreenShaped(a) ||
        const ['whatsapp', 'telegram', 'instagram', 'download', 'snapchat', 'facebook']
            .any(path.contains);
  }

  /// Phone screens are much taller than camera photos (≈ 20:9 vs 4:3 or 16:9).
  bool _isPhoneScreenShaped(AssetEntity a) {
    final w = a.orientatedWidth, h = a.orientatedHeight;
    return w > 0 && h / w >= 1.9;
  }

  /// Decides if a non-folder image is really a screenshot, from its shape and
  /// how much text it has.
  bool _looksLikeScreenshot(AssetEntity a, String text) =>
      _isPhoneScreenShaped(a) || text.replaceAll(RegExp(r'\s'), '').length >= 60;

  void dispose() {
    _ocr.close();
    _faces.close();
  }
}

/// Decodes a JPEG/PNG thumbnail into a [GrayImage]. Runs in a background isolate.
GrayImage? decodeGray(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final px = Uint8List(decoded.width * decoded.height);
  var i = 0;
  for (final p in decoded) {
    px[i++] = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255);
  }
  return GrayImage(decoded.width, decoded.height, px);
}

/// Moves items to Android's system Trash (restorable for 30 days).
/// Android shows one confirmation dialog for the whole batch.
Future<List<String>> moveToTrash(List<AssetEntity> assets) async {
  if (Platform.isAndroid) {
    return PhotoManager.editor.android.moveToTrash(assets);
  }
  return PhotoManager.editor.deleteWithIds(assets.map((a) => a.id).toList());
}
