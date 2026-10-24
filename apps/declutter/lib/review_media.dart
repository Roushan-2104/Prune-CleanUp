import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:phone_link/phone_link.dart';

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
  Future<_StreamServer>? _server;
  late final _FrameGrabber _grabber = _FrameGrabber(this);

  /// Where the player should read [f] from: a local copy for small files,
  /// a private streaming address for big ones.
  Future<String?> playableSource(PhoneFile f) async {
    if (f.bytes <= smallFile) return (await previews.get(f))?.uri.toString();
    return (await streamUrl(f)).toString();
  }

  Future<Uri> streamUrl(PhoneFile f) async => (await (_server ??= _StreamServer.start(_streamer))).urlFor(f);

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

  Future<void> dispose() async {
    await _grabber.dispose();
    final server = await _server;
    await server?.close();
    await _streamer.close();
  }
}

/// A private web address on this laptop (127.0.0.1 only) that serves phone
/// files to the player, fetching only the byte ranges it asks for.
class _StreamServer {
  _StreamServer._(this._http, this._streamer) {
    _http.listen(_handle);
  }

  static Future<_StreamServer> start(PhoneStreamer s) async =>
      _StreamServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), s);

  final HttpServer _http;
  final PhoneStreamer _streamer;
  final _byToken = <String, PhoneFile>{};
  final _tokenFor = <String, String>{};
  final _random = Random.secure();

  Uri urlFor(PhoneFile f) {
    final token = _tokenFor.putIfAbsent(f.path, () {
      final t = List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      _byToken[t] = f;
      return t;
    });
    return Uri.parse('http://127.0.0.1:${_http.port}/$token/${Uri.encodeComponent(f.name)}');
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final f = _byToken[req.uri.pathSegments.firstOrNull];
    if (f == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    // "Range: bytes=start-end" → serve just that part.
    var start = 0, end = f.bytes - 1;
    final range = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(req.headers.value(HttpHeaders.rangeHeader) ?? '');
    if (range != null) {
      final a = int.tryParse(range.group(1)!), b = int.tryParse(range.group(2)!);
      if (a == null && b != null) {
        start = max(0, f.bytes - b); // last b bytes
      } else {
        start = a ?? 0;
        end = min(b ?? end, f.bytes - 1);
      }
      if (start > end || start >= f.bytes) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${f.bytes}');
        await res.close();
        return;
      }
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${f.bytes}');
    }
    res.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, f.mime)
      ..contentLength = end - start + 1;
    if (req.method == 'HEAD') {
      await res.close();
      return;
    }
    try {
      var pos = start;
      while (pos <= end) {
        final n = min(1 << 20, end - pos + 1);
        final data = await _streamer.read(f.path, f.bytes, pos, n);
        res.add(data);
        await res.flush();
        pos += n;
        _streamer.readAhead(f.path, f.bytes, pos, 2 << 20); // keep ahead of the player
      }
      await res.close();
    } catch (_) {
      // The player moved on (seek, pause, closed): stop sending.
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> close() => _http.close(force: true);
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
      final player = _player ??= Player();
      await noDiskCache(player);
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

/// Streams come from memory; stop the player trying (and failing) to keep
/// its own cache file on disk.
Future<void> noDiskCache(Player p) async {
  final native = p.platform;
  if (native is NativePlayer) await native.setProperty('cache-on-disk', 'no');
}
