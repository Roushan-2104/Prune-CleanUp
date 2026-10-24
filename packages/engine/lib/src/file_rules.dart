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

/// Places Declutter never suggests touching: things the user hid on
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
    for (final copy in group.skip(1)) {
      result[copy.path] = FileVerdict(
        Verdict(JunkCategory.exactDuplicate, 0.99, ['Exact copy of ${keep.folder}${keep.name}']),
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

    if (!f.isVideo) continue;
    final ageDays = now.difference(DateTime.fromMillisecondsSinceEpoch(f.modifiedSec * 1000)).inDays;

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
  return result;
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
