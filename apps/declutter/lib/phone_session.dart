import 'dart:async';
import 'dart:io';

import 'package:declutter_engine/declutter_engine.dart';
import 'package:declutter_store/declutter_store.dart';
import 'package:flutter/foundation.dart';
import 'package:phone_link/phone_link.dart';

import 'photo_scan.dart';

enum LinkState { noAdb, waiting, unauthorized, reading, ready, forgotten, error }

/// What's on the phone, grouped for the overview screen.
class PhoneSummary {
  PhoneSummary(this.files);
  final List<PhoneFile> files;

  Iterable<PhoneFile> get photos => files.where((f) => f.isImage);
  Iterable<PhoneFile> get videos => files.where((f) => f.isVideo);
  Iterable<PhoneFile> get audio => files.where((f) => f.isAudio);
  Iterable<PhoneFile> get other => files.where((f) => !f.isImage && !f.isVideo && !f.isAudio);

  Iterable<PhoneFile> get hidden => files.where((f) => f.hiddenFromMediaList);

  static int bytes(Iterable<PhoneFile> fs) => fs.fold(0, (s, f) => s + f.bytes);

  /// Biggest folders by size, e.g. "WhatsApp Video" → 4.1 GB.
  List<MapEntry<String, int>> topFolders([int n = 6]) {
    final sizes = <String, int>{};
    for (final f in files) {
      sizes.update(f.folder, (v) => v + f.bytes, ifAbsent: () => f.bytes);
    }
    return (sizes.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(n).toList();
  }
}

/// Watches for a phone over USB and reads it — never changes anything on it
/// (every phone command goes through phone_link's read-only guard).
class PhoneSession extends ChangeNotifier {
  PhoneSession(this.store) {
    _adbPath = findAdb();
    if (_adbPath == null) {
      state = LinkState.noAdb;
    } else {
      _adb = Adb(_adbPath!);
      _poll();
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    }
  }

  final Store store;
  String? _adbPath;
  Adb? _adb;
  Timer? _timer;
  bool _busy = false;

  LinkState state = LinkState.waiting;
  String? serial;
  PhoneInfo? info;
  PhoneSummary? summary;
  Duration? listTime;
  String? error;

  /// What changed on the phone since it was last connected (null on the very
  /// first connection) and how many files still need to be analysed.
  InventoryDiff? sinceLastTime;
  int needAnalysis = 0;

  /// What is happening while [state] is [LinkState.reading].
  String readingStep = '';

  /// Every suggestion, by path: file facts and on-phone fingerprints, plus
  /// what the photo check has measured so far.
  Map<String, FileVerdict> suggestions = {};
  Map<String, FileVerdict> _fileLevel = {};
  List<String> _apps = const [];

  /// Checks photos and screenshots in the background once the phone is read.
  PhotoScan? photos;
  int _photosDone = -1;

  /// Every connected phone (real and virtual), and the one the user picked.
  List<PhoneDevice> devices = [];
  String? _wanted;

  Adb get adb => _adb!;
  bool get isVirtual => serial != null && PhoneCleaner.isVirtualPhone(serial!);

  /// Shows a different connected phone.
  Future<void> choose(String s) async {
    await _idle();
    _wanted = s;
    serial = null; // forces a fresh read
    await _poll();
  }

  /// Deletes everything this laptop saved about the connected phone. It then
  /// shows as forgotten until it's unplugged or read again.
  Future<void> forgetPhone() async {
    final s = serial, p = photos;
    if (s == null) return;
    _step('Forgetting this phone…');
    _stopPhotos();
    // A batch already being checked would otherwise save after the wipe.
    while (p != null && p.running) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    store.forgetPhone(s);
    suggestions = {};
    _fileLevel = {};
    summary = null;
    _set(LinkState.forgotten);
  }

  /// Reads the current phone again (after a clean-up or undo).
  Future<void> rescan() async {
    await _idle();
    _wanted = serial;
    serial = null;
    await _poll();
  }

  /// Waits for the regular 2-second check to finish, so a requested re-read
  /// is never silently skipped.
  Future<void> _idle() async {
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _poll() async {
    if (_busy) return;
    _busy = true;
    try {
      final phones = await _adb!.devices();
      if (phones.map((p) => p.serial).join() != devices.map((p) => p.serial).join()) {
        devices = phones;
        notifyListeners();
      }
      final phone =
          phones.where((p) => p.serial == _wanted && p.ready).firstOrNull ??
          phones.where((p) => p.ready).firstOrNull ??
          phones.firstOrNull;
      if (phone == null) {
        _set(LinkState.waiting, clear: true);
      } else if (!phone.ready) {
        _set(LinkState.unauthorized, clear: true);
      } else if (phone.serial != serial || state == LinkState.error) {
        await _read(phone.serial);
      }
    } on PhoneDisconnected {
      _set(LinkState.waiting, clear: true);
    } catch (e) {
      error = '$e';
      _set(LinkState.error);
    } finally {
      _busy = false;
    }
  }

  Future<void> _read(String s) async {
    serial = s;
    _set(LinkState.reading);
    info = await _adb!.info(s);
    notifyListeners();
    _step('Listing every file, including ones Android hides…');
    final sw = Stopwatch()..start();
    final files = await _adb!.listAllFiles(s);
    summary = PhoneSummary(files);
    listTime = sw.elapsed;

    final firstTime = store.fileCount(s) == 0;
    store.rememberPhone(s, info!);
    final diff = store.syncInventory(s, files);
    sinceLastTime = firstTime ? null : diff;
    needAnalysis = store.needingAnalysis(s).length;

    // Exact duplicates: only same-size files need a fingerprint, and the
    // phone computes it itself — nothing is copied.
    final facts = [
      for (final f in files)
        FileFacts(
          path: f.path,
          folder: f.folder,
          bytes: f.bytes,
          mime: f.mime,
          modifiedSec: f.modifiedSec,
          durationMs: f.durationMs,
        ),
    ];
    final candidates = sameSizeCandidates(facts);
    _step('Checking possible duplicates on the phone…');
    // Fingerprints of unchanged files are remembered; only new or changed
    // ones are asked for (that took ~20 s on every connection).
    final hashes = store.fingerprints(s);
    final ask = [for (final c in candidates) if (!hashes.containsKey(c.path)) c.path];
    final fresh = await _adb!.fingerprints(s, ask,
        onProgress: (n) => _step('Checking possible duplicates on the phone… $n of ${ask.length}'));
    store.saveFingerprints(s, fresh);
    hashes.addAll(fresh);
    _fileLevel = classifyFiles(facts, now: DateTime.now(), contentHash: hashes);
    try {
      _apps = await _adb!.installedApps(s); // names the apps screenshots come from
    } on PhoneDisconnected {
      rethrow;
    } catch (_) {
      _apps = const [];
    }

    _stopPhotos();
    photos = PhotoScan(adb: _adb!, serial: s, store: store)..addListener(_onPhotos);
    _step('Sorting photos and screenshots…');
    await _rejudge();
    _set(LinkState.ready);
    unawaited(photos!.run(files));
  }


  /// Photo results appear batch by batch, without waiting for the end.
  void _onPhotos() {
    final p = photos;
    if (p == null || summary == null) return;
    final progress = p.running ? p.done : -2;
    if (progress != _photosDone) {
      _photosDone = progress;
      unawaited(_rejudge());
    }
    notifyListeners();
  }

  bool _judging = false, _judgeAgain = false;

  /// Re-judges every measured photo on a background thread, so the window
  /// never freezes. Calls that arrive meanwhile fold into one more run.
  Future<void> _rejudge() async {
    if (_judging) {
      _judgeAgain = true;
      return;
    }
    _judging = true;
    try {
      do {
        _judgeAgain = false;
        final p = photos, s = serial, files = summary?.files;
        if (p == null || s == null || files == null) return;
        final images = await p.judgeInBackground(files, installedApps: _apps);
        if (!identical(p, photos) || serial != s) return; // the phone changed meanwhile
        suggestions = mergeSuggestions(_fileLevel, images);
        needAnalysis = store.needingAnalysis(s).length;
        notifyListeners();
      } while (_judgeAgain);
    } finally {
      _judging = false;
    }
  }

  void _stopPhotos() {
    photos
      ?..removeListener(_onPhotos)
      ..stop();
    photos = null;
    _photosDone = -1;
  }

  void _step(String text) {
    readingStep = text;
    notifyListeners();
  }

  void _set(LinkState s, {bool clear = false}) {
    if (clear) {
      _stopPhotos();
      serial = null;
      info = null;
      summary = null;
      suggestions = {};
    }
    if (state == s && !clear) return;
    state = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stopPhotos();
    store.close();
    super.dispose();
  }

  /// adb.exe: next to Declutter (when bundled), the Android SDK, or PATH.
  static String? findAdb() {
    final env = Platform.environment;
    final candidates = [
      '${File(Platform.resolvedExecutable).parent.path}\\adb\\adb.exe',
      if (env['ANDROID_HOME'] != null) '${env['ANDROID_HOME']}\\platform-tools\\adb.exe',
      if (env['LOCALAPPDATA'] != null) '${env['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools\\adb.exe',
      // Only absolute PATH entries: a relative one (".") would resolve to
      // whatever folder Declutter was started from.
      for (final dir in (env['PATH'] ?? '').split(';'))
        if (RegExp(r'^[A-Za-z]:\\|^\\\\').hasMatch(dir.trim())) '${dir.trim()}\\adb.exe',
    ];
    return candidates.where((p) => File(p).existsSync()).firstOrNull;
  }
}

String formatBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(0)} MB';
  return '${(b / 1024).toStringAsFixed(0)} KB';
}

/// 11729 → "11,729".
String formatCount(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');
