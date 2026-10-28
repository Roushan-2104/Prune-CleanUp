/// One file on the phone's shared storage.
class PhoneFile {
  const PhoneFile({
    this.id,
    required this.path,
    required this.folder,
    required this.bytes,
    required this.mime,
    required this.modifiedSec,
    this.takenMs,
    this.width,
    this.height,
    this.durationMs,
  });

  /// The phone's media-list (MediaStore) id; null for files Android doesn't
  /// list — e.g. WhatsApp's "Sent" and "Private" folders.
  final String? id;

  bool get hiddenFromMediaList => id == null;

  /// Full path on the phone, e.g. /storage/emulated/0/DCIM/Camera/IMG_1.jpg
  final String path;

  /// Folder relative to the phone's storage, e.g. "DCIM/Camera/".
  final String folder;
  final int bytes;
  final String mime;
  final int modifiedSec;
  final int? takenMs;
  final int? width;
  final int? height;
  final int? durationMs;

  String get name => path.substring(path.lastIndexOf('/') + 1);
  bool get isImage => mime.startsWith('image/');
  bool get isVideo => mime.startsWith('video/');
  bool get isAudio => mime.startsWith('audio/');

  @override
  String toString() => 'PhoneFile($path, $bytes B, $mime)';
}

/// Columns requested from MediaStore, in this exact order. The path comes
/// last (a value runs to the end of the line) and is checked against the
/// folder and name, so a file name can't pass itself off as another file.
const mediaColumns = [
  '_id', 'relative_path', '_size', 'mime_type',
  'date_modified', 'datetaken', 'width', 'height', 'duration', '_display_name', '_data',
];

/// Parses the text printed by `content query` into [PhoneFile]s.
///
/// Each row looks like:
///   Row: 0 _id=12, _data=/storage/.../a, b.jpg, relative_path=DCIM/, ...
/// Values may themselves contain ", " (file names do), so each value runs
/// until the *next known column* — not until the next comma.
///
/// Folders, deleted-but-pending entries and rows without a path are skipped.
List<PhoneFile> parseMediaRows(String output) {
  final files = <PhoneFile>[];
  for (final line in output.split('\n')) {
    final row = _parseRow(line.trimRight());
    if (row == null) continue;
    final path = row['_data'];
    final mime = row['mime_type'];
    if (path == null || mime == null) continue; // folders have no mime type
    // The parts must agree: "/storage/emulated/0/" + folder + name == path.
    // A crafted name (", _data=/…/other.jpg") makes them disagree.
    final folder = row['relative_path'] ?? '', name = row['_display_name'];
    if (name == null || path != '/storage/emulated/0/$folder$name') continue;

    files.add(PhoneFile(
      id: row['_id']!,
      path: path,
      folder: row['relative_path'] ?? '',
      bytes: _int(row['_size']) ?? 0,
      mime: mime,
      modifiedSec: _int(row['date_modified']) ?? 0,
      takenMs: _int(row['datetaken']),
      width: _int(row['width']),
      height: _int(row['height']),
      durationMs: _int(row['duration']),
    ));
  }
  // A path or id listed twice can only come from a forged row: drop both.
  final paths = <String, int>{}, ids = <String, int>{};
  for (final f in files) {
    paths.update(f.path, (n) => n + 1, ifAbsent: () => 1);
    ids.update(f.id!, (n) => n + 1, ifAbsent: () => 1);
  }
  return [for (final f in files) if (paths[f.path] == 1 && ids[f.id] == 1) f];
}

/// Every path the media query printed in its `_data` column, including rows
/// [parseMediaRows] turns down (a name ending in a space or holding a
/// newline, a path listed twice…).
///
/// Such a file is still in Android's media list, so it must never be taken
/// for a hidden one and deleted outright: it is left out of the clean-up
/// altogether, since Prune can't be sure which row is really it.
///
/// Errs on the side of "listed": a path counts if it might have been printed.
class MediaListedPaths {
  MediaListedPaths(String output) : _output = output {
    for (final line in output.split('\n')) {
      // `_data` is the last column, so its value runs to the end of the line.
      // A name can itself contain ", _data=", so every place counts.
      for (var i = line.indexOf(_key); i >= 0; i = line.indexOf(_key, i + 1)) {
        final value = line.substring(i + _key.length);
        _paths
          ..add(value)
          ..add(value.endsWith('\r') ? value.substring(0, value.length - 1) : value);
      }
    }
  }

  static const _key = ', _data=';
  final String _output;
  final _paths = <String>{};

  /// Whether the media query may have printed [path].
  bool contains(String path) {
    if (_paths.contains(path)) return true;
    // A path with a line break was printed across lines: look for it whole.
    if (path.contains('\n') || path.contains('\r')) {
      for (var i = _output.indexOf('$_key$path'); i >= 0; i = _output.indexOf('$_key$path', i + 1)) {
        final end = i + _key.length + path.length;
        if (end == _output.length || _output[end] == '\n' || _output[end] == '\r') return true;
      }
    }
    return false;
  }
}

Map<String, String?>? _parseRow(String line) {
  final start = RegExp(r'^Row: \d+ ').firstMatch(line);
  if (start == null) return null;
  final body = line.substring(start.end);

  final result = <String, String?>{};
  var pos = 0;
  for (var i = 0; i < mediaColumns.length; i++) {
    final key = '${mediaColumns[i]}=';
    if (!body.startsWith(key, pos)) return null; // unexpected format
    final valueStart = pos + key.length;
    final int valueEnd;
    if (i + 1 < mediaColumns.length) {
      valueEnd = body.indexOf(', ${mediaColumns[i + 1]}=', valueStart);
      if (valueEnd < 0) return null;
      pos = valueEnd + 2;
    } else {
      valueEnd = body.length;
    }
    final value = body.substring(valueStart, valueEnd);
    result[mediaColumns[i]] = value == 'NULL' ? null : value;
  }
  return result;
}

int? _int(String? s) => s == null ? null : int.tryParse(s);
