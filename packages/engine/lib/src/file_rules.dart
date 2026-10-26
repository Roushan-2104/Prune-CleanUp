import 'verdict.dart';

/// What the engine knows about any file on the phone, without opening it.
class FileFacts {
  const FileFacts({
    required this.path,
    required this.folder,
    required this.bytes,
    required this.mime,
    required this.modifiedSec,
    this.durationMs,
  });

  final String path;

  /// Relative to the phone's storage, e.g. "DCIM/Camera/".
  final String folder;
  final int bytes;
  final String mime;
  final int modifiedSec;
  final int? durationMs;

  String get name => path.substring(path.lastIndexOf('/') + 1);
  bool get isVideo => mime.startsWith('video/');
}

/// A verdict about a file, plus the copy it was matched against (if any).
class FileVerdict {
  const FileVerdict(this.verdict, {this.matchPath});
  final Verdict verdict;
  final String? matchPath;
}

/// Places Prune never suggests touching: things the user hid on
/// purpose, other apps' private data, and WhatsApp's own backups.
bool isProtected(String folder) {
  final f = folder.toLowerCase();
  return f.startsWith('android/data/') ||
      f.startsWith('android/obb/') ||
      f.contains('/private/') ||
      f.contains('whatsapp/databases') ||
      f.contains('whatsapp/backups') ||
      f.contains('/.shared/') ||
      f.contains('/.links/');
}

bool isWhatsAppSent(String folder) {
  final f = folder.toLowerCase();
  return f.contains('whatsapp/media/') && f.contains('/sent/');
}

bool _isScreenRecording(FileFacts f) {
  final p = '${f.folder}${f.name}'.toLowerCase();
  return f.isVideo && (p.contains('screen') && p.contains('record') || p.contains('screenrecord') || f.name.toLowerCase().startsWith('screen-'));
}

/// How "original" a location is — the copy kept in a duplicate group is the
/// one in the best place (your camera roll beats a WhatsApp copy).
int _placeRank(String folder) {
  final f = folder.toLowerCase();
  if (f.startsWith('dcim/')) return 0;
  if (f.startsWith('pictures/') || f.startsWith('movies/') || f.startsWith('documents/') || f.startsWith('music/')) return 1;
  if (f.startsWith('download/')) return 2;
  if (f.contains('whatsapp') && !isWhatsAppSent(folder)) return 3;
  if (isWhatsAppSent(folder)) return 5;
  return 4;
}

const _minDuplicateBytes = 10 * 1024; // tiny files aren't worth the noise

String _whyKept(FileFacts keep, FileFacts copy) {
  final k = _placeRank(keep.folder), c = _placeRank(copy.folder);
  if (k < c) {
    return switch (k) {
      0 => 'In your camera folder: the original place',
      1 => 'In your own ${keep.folder.split('/').first} folder',
      2 => 'In Downloads, not a WhatsApp copy',
      _ => 'Received copy, not a sent copy',
    };
  }
  return 'The older copy (${shortDate(keep.modifiedSec)}), so the original';
}

/// 2345678 → "2,345,678".
String groupDigits(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Seconds since 1970 → "12 Mar 2026".
String shortDate(int sec) {
  final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// Judges files from their facts alone (no copying needed).
///
/// [contentHash] maps path → a hash of the file's bytes (computed on the
/// phone for files that share a size). Only matching hashes make two files
/// exact duplicates — equal size alone never does.
Map<String, FileVerdict> classifyFiles(List<FileFacts> files,
    {required DateTime now, Map<String, String> contentHash = const {}}) {
  final result = <String, FileVerdict>{};
  final candidates = files.where((f) => !isProtected(f.folder)).toList();

  // 1. Exact duplicates (any kind of file), confirmed by content hash.
  final byHash = <String, List<FileFacts>>{};
  for (final f in candidates) {
    final h = contentHash[f.path];
    if (h != null && f.bytes >= _minDuplicateBytes) byHash.putIfAbsent('$h:${f.bytes}', () => []).add(f);
  }
  for (final group in byHash.values.where((g) => g.length > 1)) {
    group.sort((a, b) {
      final r = _placeRank(a.folder).compareTo(_placeRank(b.folder));
      return r != 0 ? r : a.modifiedSec.compareTo(b.modifiedSec); // oldest = the original
    });
    final keep = group.first;
    final h = contentHash[keep.path]!;
    for (final copy in group.skip(1)) {
      result[copy.path] = FileVerdict(
        Verdict(JunkCategory.exactDuplicate, 0.99, ['Exact copy of ${keep.folder}${keep.name}'], evidence: {
          'Content fingerprint': '${h.length > 10 ? '${h.substring(0, 4)}…${h.substring(h.length - 4)}' : h} on both',
          'Size': '${groupDigits(copy.bytes)} bytes on both',
          'Kept copy': _whyKept(keep, copy),
        }),
        matchPath: keep.path,
      );
    }
  }

  for (final f in candidates) {
    if (result.containsKey(f.path)) continue;

    // 2. WhatsApp's copies of things you sent.
    if (isWhatsAppSent(f.folder)) {
      result[f.path] = const FileVerdict(Verdict(JunkCategory.whatsappSent, 0.75, [
        'A copy WhatsApp keeps of something you sent',
        'The chat will show it as no longer on this phone',
      ]));
      continue;
    }

    final ageDays = now.difference(DateTime.fromMillisecondsSinceEpoch(f.modifiedSec * 1000)).inDays;
    final folder = f.folder.toLowerCase();
    final name = f.name.toLowerCase();
    final months = (ageDays / 30).floor();

    // Caches the phone rebuilds by itself.
    if (folder.contains('.thumbnails/')) {
      result[f.path] = const FileVerdict(Verdict(JunkCategory.cacheFiles, 0.92,
          ['Gallery preview cache', 'Rebuilt automatically when needed']));
      continue;
    }
    if (folder.contains('whatsapp/media/.statuses/')) {
      result[f.path] = const FileVerdict(Verdict(JunkCategory.cacheFiles, 0.92,
          ['A WhatsApp status you viewed', 'Statuses expire after 24 hours anyway']));
      continue;
    }

    // App installers: the app keeps working once installed.
    if (name.endsWith('.apk') || name.endsWith('.xapk') || name.endsWith('.apks')) {
      result[f.path] = FileVerdict(ageDays >= 14
          ? Verdict(JunkCategory.oldInstaller, 0.9,
              ['App installer file, $ageDays days old', 'Installed apps keep working without it'])
          : Verdict(JunkCategory.oldInstaller, 0.7, ['App installer downloaded $ageDays days ago']));
      continue;
    }

    // Old voice notes: often kept for a reason, so never pre-selected.
    if (folder.contains('whatsapp voice notes') && ageDays > 90) {
      result[f.path] = FileVerdict(Verdict(JunkCategory.oldVoiceNote, 0.65, ['Voice note from $months months ago']));
      continue;
    }

    // Documents and downloads nobody has touched in half a year.
    final oldDocument = ageDays > 180 && f.bytes >= 1 << 20 && !f.isVideo && !f.mime.startsWith('image/');
    if (oldDocument && (folder.startsWith('download/') || folder.contains('whatsapp documents'))) {
      result[f.path] = FileVerdict(Verdict(JunkCategory.oldDocument, 0.6, [
        folder.startsWith('download/') ? 'In Downloads, untouched for $months months' : 'Received on WhatsApp $months months ago',
        'Check if you still need it',
      ]));
      continue;
    }

    if (!f.isVideo) continue;

    // 3. Camera clips too short to be intentional.
    final d = f.durationMs;
    if (d != null && d > 0 && d < 2000 && f.folder.toLowerCase().startsWith('dcim/')) {
      result[f.path] = FileVerdict(Verdict(JunkCategory.shortClip, 0.75,
          ['Only ${(d / 1000).toStringAsFixed(1)} s long — probably recorded by accident']));
      continue;
    }

    // 4. Screen recordings you've had for a while.
    if (_isScreenRecording(f)) {
      result[f.path] = FileVerdict(Verdict(JunkCategory.screenRecording, ageDays > 30 ? 0.7 : 0.6,
          ['Screen recording', if (ageDays > 30) '$ageDays days old']));
      continue;
    }

    // 5. Very large videos: worth a look, never pre-selected.
    if (f.bytes >= 500 << 20) {
      result[f.path] = FileVerdict(Verdict(JunkCategory.largeVideo, 0.62,
          ['Very large: ${(f.bytes / (1 << 30)).toStringAsFixed(1)} GB', 'Check if you still need it here']));
    }
  }
  return _withBasicEvidence(result, candidates, now);
}

/// Adds the basic facts (folder, size, date, length) as "How we know"
/// evidence to verdicts that don't carry their own.
Map<String, FileVerdict> _withBasicEvidence(Map<String, FileVerdict> result, List<FileFacts> files, DateTime now) {
  final byPath = {for (final f in files) f.path: f};
  return {
    for (final MapEntry(key: path, value: fv) in result.entries)
      path: fv.verdict.evidence.isNotEmpty
          ? fv
          : FileVerdict(
              Verdict(fv.verdict.category, fv.verdict.confidence, fv.verdict.reasons,
                  label: fv.verdict.label, evidence: _basicEvidence(byPath[path]!, now)),
              matchPath: fv.matchPath,
            ),
  };
}

Map<String, String> _basicEvidence(FileFacts f, DateTime now) {
  final days = now.difference(DateTime.fromMillisecondsSinceEpoch(f.modifiedSec * 1000)).inDays;
  final d = f.durationMs;
  return {
    'Folder': f.folder.isEmpty ? '(phone storage)' : f.folder,
    'Size': f.bytes >= 1 << 20 ? '${(f.bytes / (1 << 20)).toStringAsFixed(1)} MB' : '${(f.bytes / 1024).toStringAsFixed(0)} KB',
    'Last changed': '${shortDate(f.modifiedSec)} · $days days ago',
    if (d != null && d > 0) 'Length': '${(d / 1000).toStringAsFixed(1)} s',
  };
}

/// Files that share an exact size with another (non-protected, non-tiny)
/// file. Only these need a content hash to find exact duplicates.
List<FileFacts> sameSizeCandidates(List<FileFacts> files) {
  final bySize = <int, List<FileFacts>>{};
  for (final f in files) {
    if (f.bytes >= _minDuplicateBytes && !isProtected(f.folder)) bySize.putIfAbsent(f.bytes, () => []).add(f);
  }
  return [for (final g in bySize.values.where((g) => g.length > 1)) ...g];
}
