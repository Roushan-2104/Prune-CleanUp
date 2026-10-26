import 'dart:io';

/// Making phone file names safe to use on the laptop.
///
/// Android allows names Windows treats specially: `\` (a folder separator
/// here), `..`, `:` (an alternate data stream), trailing dots (dropped, so
/// `x.jpg.` and `x.jpg` collide), reserved names (`CON`, `NUL`…) and
/// invisible direction marks (U+202E) that make `invoice<mark>fdp.exe` display as `invoiceexe.pdf`.
/// A name from the phone must never decide *where* a laptop file goes.

final _unsafe = RegExp(r'[<>:"/\\|?*\x00-\x1f\u200e\u200f\u202a-\u202e\u2066-\u2069]');
final _reserved = RegExp(r'^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(\..*)?$', caseSensitive: false);

/// [name] as one safe Windows path segment (never a separator, never `..`).
String safeSegment(String name) {
  var s = name.replaceAll(_unsafe, '_').replaceAll(RegExp(r'[. ]+$'), '');
  if (s.isEmpty || s == '.' || s == '..') s = '_${s.replaceAll('.', '_')}';
  if (_reserved.hasMatch(s)) s = '_$s';
  return s;
}

/// Whether [name] is already safe as-is (adb may use it directly).
bool isSafeName(String name) => safeSegment(name) == name;

/// [root] joined with [segments], each made safe; throws if the result
/// would somehow leave [root].
String inside(String root, Iterable<String> segments) {
  final path = [root, ...segments.map(safeSegment)].join(Platform.pathSeparator);
  if (!isWithin(root, path)) throw ArgumentError('Refusing a path outside $root: $path');
  return path;
}

/// Whether [path] lies inside [root] once both are made absolute.
bool isWithin(String root, String path) {
  String norm(String p) => File(p).absolute.uri.normalizePath().toFilePath(windows: Platform.isWindows).toLowerCase();
  final r = norm(root), p = norm(path);
  final sep = Platform.pathSeparator;
  return p.startsWith(r.endsWith(sep) ? r : '$r$sep');
}
