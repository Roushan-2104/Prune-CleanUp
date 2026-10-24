import 'media_list.dart';

/// The phone's shared storage as `find` and MediaStore both name it.
const storageRoot = '/storage/emulated/0';

/// The `-printf` format used for full listings: size, modified time, path.
const findFormat = r'%s\t%T@\t%p\n';

/// Parses `find -printf '%s\t%T@\t%p\n'` output into [PhoneFile]s.
/// These files have no media-list id; their type comes from the extension.
List<PhoneFile> parseFindRows(String output) {
  final files = <PhoneFile>[];
  for (final raw in output.split('\n')) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    final parts = line.split('\t');
    if (parts.length != 3) continue;
    final bytes = int.tryParse(parts[0]);
    final mtime = double.tryParse(parts[1]);
    final path = parts[2];
    if (bytes == null || mtime == null || !path.startsWith('$storageRoot/')) continue;

    final relative = path.substring(storageRoot.length + 1);
    final slash = relative.lastIndexOf('/');
    if (isInPhoneTrashOrPending(relative.substring(slash + 1))) continue;
    files.add(PhoneFile(
      path: path,
      folder: slash < 0 ? '' : relative.substring(0, slash + 1),
      bytes: bytes,
      mime: mimeFromName(path),
      modifiedSec: mtime.floor(),
    ));
  }
  return files;
}

/// Android keeps files in its Trash (and half-written files) under hidden
/// names like ".trashed-1795441376-photo.jpg" / ".pending-…". They're not
/// phone content: Android deletes trashed files itself after 30 days, so
/// they must never be suggested again.
bool isInPhoneTrashOrPending(String fileName) =>
    fileName.startsWith('.trashed-') || fileName.startsWith('.pending-');

/// Everything on the phone: MediaStore's richer entries (dimensions,
/// durations, dates taken) plus the files only `find` sees.
List<PhoneFile> mergeListings(List<PhoneFile> mediaList, List<PhoneFile> found) {
  final known = {for (final f in mediaList) f.path};
  return [...mediaList, ...found.where((f) => !known.contains(f.path))];
}

const _mimeByExtension = {
  'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'webp': 'image/webp', 'gif': 'image/gif',
  'heic': 'image/heic', 'heif': 'image/heif', 'bmp': 'image/bmp',
  'mp4': 'video/mp4', '3gp': 'video/3gpp', 'mkv': 'video/x-matroska', 'mov': 'video/quicktime', 'webm': 'video/webm',
  'opus': 'audio/ogg', 'ogg': 'audio/ogg', 'mp3': 'audio/mpeg', 'm4a': 'audio/mp4', 'aac': 'audio/aac',
  'wav': 'audio/wav', 'amr': 'audio/amr',
  'pdf': 'application/pdf', 'doc': 'application/msword',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel', 'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'apk': 'application/vnd.android.package-archive', 'zip': 'application/zip', 'txt': 'text/plain',
  'vcf': 'text/vcard',
};

String mimeFromName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot < name.lastIndexOf('/')) return 'application/octet-stream';
  return _mimeByExtension[name.substring(dot + 1).toLowerCase()] ?? 'application/octet-stream';
}
