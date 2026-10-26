import 'dart:async';
import 'dart:io' show ZLibDecoder;
import 'dart:math';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:phone_link/phone_link.dart';
import 'package:vision_helper/vision_helper.dart';

import 'media_view.dart' show markFromInternet;
import 'photo_scan.dart';
import 'previews.dart';

/// Everything the review screen needs to SHOW phone files, without copying
/// big ones: small files are fetched whole (instant), big videos and audio
/// are streamed from the phone a slice at a time, and video frames
/// (thumbnails, filmstrip) are grabbed from that stream.
///
/// Read-only on the phone. Nothing streamed is written to disk; small-file
/// copies live in the preview folder, which is wiped on start and close.
class ReviewMedia {
  ReviewMedia(this.adb, this.serial) : previews = PreviewCache(adb, serial);

  final Adb adb;
  final String serial;
  final PreviewCache previews;

  /// Files up to this size are simply fetched whole.
  static const smallFile = 8 << 20;

  late final PhoneStreamer _streamer = PhoneStreamer(adb.adbPath, serial);
  Future<PhoneFileServer>? _server;
  late final _FrameGrabber _grabber = _FrameGrabber(this);

  /// Where the player should read [f] from: a local copy for small files,
  /// a private streaming address for big ones.
  ///
  /// Only files that really start like audio or video are handed to the
  /// player (see [looksLikeMedia]); anything else throws [NotMedia].
  Future<String?> playableSource(PhoneFile f) async {
    if (f.bytes <= smallFile) {
      final local = await previews.get(f);
      if (local == null) return null;
      final raf = await local.open();
      final head = await raf.read(64).whenComplete(raf.close);
      if (!looksLikeMedia(head)) throw NotMedia(f.name);
      return local.uri.toString();
    }
    final head = await _streamer.read(f.path, f.bytes, 0, 64);
    if (!looksLikeMedia(head)) throw NotMedia(f.name);
    return (await streamUrl(f)).toString();
  }

  Future<Uri> streamUrl(PhoneFile f) async => (await (_server ??= PhoneFileServer.start(_streamer))).urlFor(f);

  /// Fetches the parts a player needs first — the start and the index at
  /// the end (many phone videos keep it there) — so Play starts instantly.
  void warmUp(PhoneFile f) {
    if (!(f.isVideo || f.isAudio) || f.bytes <= smallFile) return;
    _streamer.focus(f.path); // drop read-ahead for anything else
    _streamer.readAhead(f.path, f.bytes, 0, 2 << 20);
    _streamer.readAhead(f.path, f.bytes, max(0, f.bytes - (1 << 20)), 1 << 20);
  }

  /// One frame from about 10% into a video, for the list.
  Future<Uint8List?> thumbnail(PhoneFile f) => _grabber.frames(f, const [0.1]).then((l) => l.firstOrNull);

  /// Five frames spread across a video.
  Future<List<Uint8List>> filmstrip(PhoneFile f) => _grabber.frames(f, const [0.05, 0.27, 0.5, 0.73, 0.95]);

  /// Documents bigger than this aren't copied just to show a preview.
  static const previewLimit = 64 << 20;

  final _documents = <String, Future<Uint8List?>>{};
  final _waiting = <(String, Completer<Uint8List?>)>[];
  Timer? _batch;

  /// A picture of what a non-photo file is (PNG): a PDF's first page, an
  /// app installer's own icon, or the thumbnail or type icon Windows shows
  /// for it. Made by the helper program, never inside Prune itself, from a
  /// local copy marked as downloaded from the internet.
  Future<Uint8List?> documentPreview(PhoneFile f) => _documents[f.path] ??= () async {
        if (f.name.toLowerCase().endsWith('.apk')) {
          try {
            if (await apkIcon(f) case final icon?) return icon;
          } catch (_) {
            // Not a readable zip: fall back to the type icon below.
          }
        }
        if (f.bytes > previewLimit) return null;
        final local = await previews.get(f);
        if (local == null) return null;
        markFromInternet(local.path);
        final done = Completer<Uint8List?>();
        _waiting.add((local.path, done));
        // Previews asked for together (a screenful of cards) go to the helper as one batch.
        _batch ??= Timer(const Duration(milliseconds: 150), _runBatch);
        return done.future;
      }();

  /// An app installer's own icon, read straight from the phone without
  /// copying the whole .apk: an .apk is a zip, so only its table of contents
  /// (at the end) and the icon's few kilobytes are fetched. PNG or WebP.
  Future<Uint8List?> apkIcon(PhoneFile f) async {
    Future<ByteData> read(int offset, int length) async =>
        ByteData.sublistView(await _streamer.read(f.path, f.bytes, offset, length));

    // The zip's end record sits in the last 64 KB.
    final tailStart = max(0, f.bytes - 66000);
    final tail = await read(tailStart, f.bytes - tailStart);
    var end = -1;
    for (var i = tail.lengthInBytes - 22; i >= 0; i--) {
      if (tail.getUint32(i, Endian.little) == 0x06054b50) {
        end = i;
        break;
      }
    }
    if (end < 0) return null;
    final dirSize = tail.getUint32(end + 12, Endian.little), dirAt = tail.getUint32(end + 16, Endian.little);
    if (dirSize > (8 << 20) || dirAt + dirSize > f.bytes) return null;

    // The table of contents: pick the launcher icon (not an adaptive-icon layer), biggest first.
    final dir = await read(dirAt, dirSize);
    ({int at, int size, int method, int packed})? best;
    var bestRank = 0;
    for (var p = 0; p + 46 <= dir.lengthInBytes && dir.getUint32(p, Endian.little) == 0x02014b50;) {
      final method = dir.getUint16(p + 10, Endian.little);
      final packed = dir.getUint32(p + 20, Endian.little), size = dir.getUint32(p + 24, Endian.little);
      final nameLength = dir.getUint16(p + 28, Endian.little);
      final skip = dir.getUint16(p + 30, Endian.little) + dir.getUint16(p + 32, Endian.little);
      final at = dir.getUint32(p + 42, Endian.little);
      final name = String.fromCharCodes(Uint8List.sublistView(dir, p + 46, p + 46 + nameLength)).toLowerCase();
      p += 46 + nameLength + skip;
      final file = name.substring(name.lastIndexOf('/') + 1);
      if (!name.startsWith('res/') || !(name.endsWith('.png') || name.endsWith('.webp'))) continue;
      if (!file.startsWith('ic_launcher') && !file.startsWith('app_icon') && !file.contains('launcher')) continue;
      if (size > (2 << 20) || packed > (2 << 20) || (method != 0 && method != 8)) continue; // never unpack anything big
      final rank = file.contains('foreground') || file.contains('background') || file.contains('monochrome') ? 1 : 2;
      if (rank > bestRank || (rank == bestRank && size > best!.size)) {
        best = (at: at, size: size, method: method, packed: packed);
        bestRank = rank;
      }
    }
    if (best == null) return null;

    // The icon itself: a 30-byte header, its name and extra field, then the data.
    final header = await read(best.at, 30);
    if (header.getUint32(0, Endian.little) != 0x04034b50) return null;
    final dataAt = best.at + 30 + header.getUint16(26, Endian.little) + header.getUint16(28, Endian.little);
    final packed = Uint8List.sublistView(await read(dataAt, best.packed));
    final data = best.method == 0 ? packed : Uint8List.fromList(ZLibDecoder(raw: true).convert(packed));
    return data.length == best.size ? data : null;
  }

  Future<void> _runBatch() async {
    final batch = [..._waiting];
    _waiting.clear();
    _batch = null;
    final exe = PhotoScan.findVisionHelper();
    if (exe == null) {
      for (final (_, done) in batch) {
        done.complete(null);
      }
      return;
    }
    try {
      final results = await Vision(exe, parallel: 1, batchSize: batch.length)
          .analyseEach([for (final (path, _) in batch) VisionJob(path, thumb: true)]);
      for (final (i, (_, done)) in batch.indexed) {
        done.complete(results[i].thumb);
      }
    } catch (_) {
      for (final (_, done) in batch) {
        if (!done.isCompleted) done.complete(null);
      }
    }
  }

  Future<void> dispose() async {
    _batch?.cancel();
    for (final (_, done) in _waiting) {
      done.complete(null);
    }
    await _grabber.dispose();
    final server = await _server;
    await server?.close();
    await _streamer.close();
  }
}

/// Grabs still frames from videos with a hidden player, one video at a
/// time, and remembers them for this review session (in memory only).
class _FrameGrabber {
  _FrameGrabber(this.media);
  final ReviewMedia media;

  Player? _player;
  // ignore: unused_field — keeps the video output alive for screenshots
  VideoController? _video;
  Future<void> _lane = Future.value();
  final _cache = <String, Uint8List?>{};

  Future<List<Uint8List>> frames(PhoneFile f, List<double> at) {
    final wanted = [for (final p in at) '${f.path}@$p'];
    if (wanted.every(_cache.containsKey)) return Future.value([for (final k in wanted) ?_cache[k]]);
    final job = _lane.then((_) => _grab(f, at));
    _lane = job.then((_) {}, onError: (_) {});
    return job;
  }

  Future<List<Uint8List>> _grab(PhoneFile f, List<double> at) async {
    final out = <Uint8List>[];
    try {
      final player = _player ??= safePlayer();
      await hardenPlayer(player);
      _video ??= VideoController(player);
      await player.setVolume(0);
      final src = await media.playableSource(f);
      if (src == null) return out;
      await player.open(Media(src), play: false);
      final duration = await player.stream.duration.firstWhere((d) => d > Duration.zero).timeout(const Duration(seconds: 15));
      for (final p in at) {
        final key = '${f.path}@$p';
        if (_cache.containsKey(key)) {
          if (_cache[key] != null) out.add(_cache[key]!);
          continue;
        }
        await player.seek(duration * p);
        await Future<void>.delayed(const Duration(milliseconds: 350)); // let the frame decode
        final shot = await player.screenshot(format: 'image/jpeg');
        _cache[key] = shot;
        if (shot != null) out.add(shot);
      }
      await player.stop();
    } catch (_) {
      // A frame we can't get just isn't shown; the item stays reviewable.
    }
    return out;
  }

  Future<void> dispose() async {
    await _player?.dispose();
    _player = null;
    _video = null;
    _cache.clear();
  }
}

/// A file the player is not given: it doesn't start like audio or video.
class NotMedia implements Exception {
  NotMedia(this.name);
  final String name;
  @override
  String toString() => '$name is not a real video or audio file, so Prune won\'t play it.';
}

/// Whether [head] (a file's first bytes) starts like a real audio or video
/// file. A text file named ".mp4" can be a playlist that makes the player
/// fetch addresses from the internet or open other files on the laptop;
/// those, and anything else unrecognised, are never played.
bool looksLikeMedia(List<int> head) {
  bool at(int offset, String magic) =>
      head.length >= offset + magic.length &&
      Iterable<int>.generate(magic.length).every((i) => head[offset + i] == magic.codeUnitAt(i));
  bool bytes(List<int> magic) =>
      head.length >= magic.length && Iterable<int>.generate(magic.length).every((i) => head[i] == magic[i]);
  return at(4, 'ftyp') || // MP4, MOV, 3GP, M4A
      bytes([0x1A, 0x45, 0xDF, 0xA3]) || // Matroska, WebM
      at(0, 'RIFF') || // AVI, WAV
      at(0, 'OggS') || // Ogg, Opus (WhatsApp voice notes)
      at(0, 'fLaC') ||
      at(0, '#!AMR') ||
      at(0, 'ID3') || // MP3 with tags
      (head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) || // MP3 / AAC frames
      bytes([0x00, 0x00, 0x01, 0xBA]) || bytes([0x00, 0x00, 0x01, 0xB3]) || // MPEG-PS
      (head.isNotEmpty && head[0] == 0x47); // MPEG-TS sync byte
}

/// A player for files from the phone, which are untrusted: it reads only
/// local copies and Prune's own 127.0.0.1 stream, and only real audio
/// and video formats (see also [looksLikeMedia]).
Player safePlayer() => Player(configuration: const PlayerConfiguration(protocolWhitelist: ['file', 'http', 'tcp']));

/// Locks down a player made by [safePlayer] before it opens anything.
/// (The player opens every file through a small playlist of its own, so
/// playlists as such can't be switched off; [looksLikeMedia] keeps
/// phone-made ones out.)
Future<void> hardenPlayer(Player p) async {
  final native = p.platform;
  if (native is! NativePlayer) return;
  for (final MapEntry(key: k, value: v) in const {
    'cache-on-disk': 'no', // streams come from memory; no cache file on disk
    'ytdl': 'no', // never hand a URL to a downloader
    'load-scripts': 'no',
    // Both lists together: setting this replaces the player's own value.
    'demuxer-lavf-o': 'strict=experimental,protocol_whitelist=[file,http,tcp],'
        'format_whitelist=[mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,avi,mpeg,mpegts,mp3,aac,ogg,flac,wav,amr]',
  }.entries) {
    await native.setProperty(k, v);
  }
}
