import 'dart:io';
import 'dart:isolate';

import 'package:declutter_engine/declutter_engine.dart';
import 'package:declutter_store/declutter_store.dart';
import 'package:flutter/foundation.dart';
import 'package:phone_link/phone_link.dart';
import 'package:vision_helper/vision_helper.dart';

/// Checks photos and screenshots on the laptop, read-only on the phone:
/// copy a batch → read text (screenshots) and a small grayscale copy
/// (every photo) with Windows' engines → check faces on blurry-looking ones
/// → save only the measurements → delete the copies → next batch.
///
/// Stopping is safe: finished batches are saved and skipped next time.
class PhotoScan extends ChangeNotifier {
  PhotoScan({required this.adb, required this.serial, required this.store});

  final Adb adb;
  final String serial;
  final Store store;

  static const batchSize = 200;

  bool running = false;
  int total = 0;
  int done = 0;
  int unreadable = 0;
  String step = '';
  String? error;
  bool _stop = false;
  final _clock = Stopwatch();
  int _copyMs = 0, _readMs = 0, _faceMs = 0; // last batch, for the log

  /// Time left, once a couple of batches have shown the real speed.
  Duration? get timeLeft {
    if (done < batchSize || total == 0) return null;
    final perItem = _clock.elapsedMilliseconds / done;
    return Duration(milliseconds: (perItem * (total - done)).round());
  }

  void stop() {
    _stop = true;
    step = 'Stopping after this batch…';
    notifyListeners();
  }

  static ImageFacts factsOf(PhoneFile f) => ImageFacts(
        path: f.path, folder: f.folder, bytes: f.bytes, modifiedSec: f.modifiedSec,
        takenMs: f.takenMs, width: f.width, height: f.height,
      );

  /// Images on the phone worth checking, keyed by path.
  static Map<String, ImageFacts> imagesOf(List<PhoneFile> files) => {
        for (final f in files)
          if (f.isImage)
            if (factsOf(f) case final facts when shouldAnalyseImage(facts)) f.path: facts,
      };

  /// How many images still need checking (new or changed since last time).
  int pending() => running ? total - done : _pending ??= _countPending();
  int? _pending; // remembered between runs; Home asks on every redraw

  int _countPending() {
    final images = imagesOf(_files);
    return store.needingAnalysis(serial).where(images.containsKey).length;
  }

  /// Carries on after a pause; already-checked photos are skipped.
  Future<void> resume() => run(_files);
  List<PhoneFile> _files = const [];

  /// Image suggestions from everything measured so far (instant: no copying).
  /// Re-run after every batch, so screenshot groups ("Neel7 · WhatsApp",
  /// "LeetCode") build up while the check runs.
  Map<String, FileVerdict> judge(List<PhoneFile> files, {List<String> installedApps = const []}) {
    final images = imagesOf(files);
    final measured = {
      for (final MapEntry(key: p, value: a) in store.measurements(serial).entries)
        if (images.containsKey(p)) p: a,
    };
    return judgeImages(measured, images, installedPackages: installedApps);
  }

  /// [judge] on a background thread (only the database read stays here):
  /// with 16,000+ photos it takes seconds, which froze the window.
  Future<Map<String, FileVerdict>> judgeInBackground(List<PhoneFile> files, {List<String> installedApps = const []}) {
    final images = imagesOf(files);
    final measured = {
      for (final MapEntry(key: p, value: a) in store.measurements(serial).entries)
        if (images.containsKey(p)) p: a,
    };
    return Isolate.run(() => judgeImages(measured, images, installedPackages: installedApps));
  }

  Future<void> run(List<PhoneFile> files) async {
    if (running) return;
    _files = files;
    final exe = findVisionHelper();
    if (exe == null) {
      error = 'The text-reading helper (DeclutterVision.exe) is missing.';
      notifyListeners();
      return;
    }
    running = true;
    _pending = null;
    _stop = false;
    error = null;
    done = 0;
    unreadable = 0;
    _clock
      ..reset()
      ..start();

    final images = imagesOf(files);
    final byPath = {for (final f in files) f.path: f};
    final todo = [for (final p in store.needingAnalysis(serial)) if (images.containsKey(p)) byPath[p]!];
    total = todo.length;
    notifyListeners();

    // A Wi-Fi serial is "ip:port", and ':' in a folder name is an alternate data stream.
    final work = Directory(inside(workRoot.path, ['$serial-${DateTime.now().millisecondsSinceEpoch}']));
    // Text reading is CPU-bound: 8 helpers measured fastest on a 12-thread laptop.
    final vision = Vision(exe, parallel: (Platform.numberOfProcessors - 4).clamp(2, 8), batchSize: 15);
    final batches = [for (var i = 0; i < todo.length; i += batchSize) todo.sublist(i, (i + batchSize).clamp(0, todo.length))];
    // The next batch copies over USB while this one is being read.
    Future<List<PhoneFile>>? next;
    try {
      if (batches.isNotEmpty) next = _copy(batches.first, work);
      for (var i = 0; i < batches.length && !_stop; i++) {
        final t = _clock.elapsedMilliseconds;
        final copied = await next!;
        next = i + 1 < batches.length && !_stop ? _copy(batches[i + 1], work) : null;
        await _measure(copied, images, work, vision);
        done += batches[i].length;
        debugPrint('photo check: $done of $total, ${batches[i].length} in ${_clock.elapsedMilliseconds - t} ms '
            '(copy $_copyMs, read $_readMs, faces $_faceMs)');
        step = '';
        notifyListeners();
      }
    } catch (e) {
      error = e is PhoneDisconnected ? 'The phone was disconnected. Checked photos are saved.' : '$e';
    } finally {
      await next?.then((_) {}, onError: (_) {}); // never delete under a copy in progress
      if (work.existsSync()) work.deleteSync(recursive: true);
      running = false;
      _pending = null; // recounted on next ask
      _clock.stop();
      notifyListeners();
    }
  }

  static String _local(Directory work, PhoneFile f) =>
      inside(work.path, ['${f.path.hashCode.toUnsigned(32).toRadixString(16)}_${f.name}']);

  Future<List<PhoneFile>> _copy(List<PhoneFile> batch, Directory work) async {
    final sw = Stopwatch()..start();
    final copied = (await adb.copyManyToLaptop(serial, batch, (f) => _local(work, f))).copied;
    _copyMs = sw.elapsedMilliseconds;
    return copied;
  }

  Future<void> _measure(List<PhoneFile> copied, Map<String, ImageFacts> images, Directory work, Vision vision) async {
    String local(PhoneFile f) => _local(work, f);
    step = 'Reading text and sharpness of ${copied.length} photos…';
    notifyListeners();
    final sw = Stopwatch()..start();
    final results = await vision.analyseEach([
      for (final f in copied) VisionJob(local(f), gray: true, text: mightBeScreenshot(images[f.path]!)),
    ]);
    _readMs = sw.elapsedMilliseconds;
    _faceMs = 0;

    final analyses = <String, Analysis>{};
    final faceCheck = <PhoneFile>[];
    for (final (i, f) in copied.indexed) {
      final r = results[i], g = r.gray;
      if (!r.ok || g == null) {
        // Windows can't open it (damaged, or a format it lacks). Remembered
        // without measurements, so it is never suggested and not retried
        // until the file changes.
        debugPrint('photo check: could not read ${f.path}: ${r.error}');
        unreadable++;
        analyses[f.path] = Analysis(modified: f.modifiedSec, bytes: f.bytes,
            takenAtMs: f.takenMs ?? f.modifiedSec * 1000, screenshot: false);
        continue;
      }
      final facts = images[f.path]!;
      final gray = GrayImage(g.width, g.height, g.pixels);
      final screenshot = r.text != null && looksLikeScreenshot(facts, r.text, width: g.width, height: g.height);
      final a = Analysis(
        modified: f.modifiedSec,
        bytes: f.bytes,
        takenAtMs: f.takenMs ?? f.modifiedSec * 1000,
        screenshot: screenshot,
        text: r.text,
        dHash: dHash(gray),
        sharpness: bestTileSharpness(gray),
        entropy: entropy(gray),
        landscape: g.width > g.height,
      );
      analyses[f.path] = a;
      if (!screenshot && classifyBlurMetrics(sharpness: a.sharpness!, entropy: a.entropy!) != null) faceCheck.add(f);
    }

    // People in a blurry photo? Then it's never pre-ticked.
    if (faceCheck.isNotEmpty) {
      step = 'Checking ${faceCheck.length} blurry-looking photos for people…';
      notifyListeners();
      sw.reset();
      final faces = await vision.analyseEach([for (final f in faceCheck) VisionJob(local(f), faces: true)]);
      _faceMs = sw.elapsedMilliseconds;
      for (final (i, f) in faceCheck.indexed) {
        if (faces[i].faces case final n?) analyses[f.path] = analyses[f.path]!.withFaceCount(n);
      }
    }

    store.saveMeasurements(serial, analyses);
    for (final f in copied) {
      try {
        File(local(f)).deleteSync();
      } catch (_) {}
    }
  }

  /// %LOCALAPPDATA%\Declutter\work — copies being checked, one folder per run.
  static Directory get workRoot =>
      Directory('${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}\\Declutter\\work');

  /// Removes copies left behind if Declutter was closed mid-check.
  static void clearWork() {
    try {
      if (workRoot.existsSync()) workRoot.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// DeclutterVision.exe: next to Declutter when installed, or the
  /// project's build folder during development.
  static String? findVisionHelper() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final beside = File('${exeDir.path}\\DeclutterVision.exe');
    if (beside.existsSync()) return beside.path;
    for (final start in [exeDir, Directory.current]) {
      for (Directory d = start.absolute; d.path != d.parent.path; d = d.parent) {
        final dev = File('${d.path}\\packages\\vision_helper\\bin\\DeclutterVision.exe');
        if (dev.existsSync()) return dev.path;
      }
    }
    return null;
  }
}
