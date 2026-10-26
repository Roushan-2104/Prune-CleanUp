import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'media_list.dart';
import 'streamer.dart';

/// A private web address on this laptop (127.0.0.1 only, random secret
/// paths) that serves phone files to a video player, fetching from the
/// phone only the byte ranges the player asks for. Read-only.
class PhoneFileServer {
  PhoneFileServer._(this._http, this.streamer) {
    _http.listen(_handle);
  }

  static Future<PhoneFileServer> start(PhoneStreamer s) async =>
      PhoneFileServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), s);

  final HttpServer _http;
  final PhoneStreamer streamer;
  final _byToken = <String, PhoneFile>{};
  final _tokenFor = <String, String>{};
  final _random = Random.secure();

  /// Requests currently being answered (for diagnostics and tests).
  int active = 0;

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
    if (f == null || (req.method != 'GET' && req.method != 'HEAD')) {
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
      ..set(HttpHeaders.contentTypeHeader,
            RegExp(r'^[a-z]+/[a-z0-9.+-]+$').hasMatch(f.mime) ? f.mime : 'application/octet-stream') // from the phone: never trusted as-is
      ..set(HttpHeaders.connectionHeader, 'close')
      ..contentLength = end - start + 1;
    if (req.method == 'HEAD') {
      await res.close();
      return;
    }

    // Take the raw connection so we learn the INSTANT the player hangs up
    // (it does on every seek, pause and switch) and stop reading the phone.
    // Dart's normal response object only notices on a later write, so
    // abandoned requests kept pulling whole videos and jammed the phone link.
    final socket = await res.detachSocket();
    var gone = false;
    socket.listen((_) {}, onDone: () => gone = true, onError: (_) => gone = true, cancelOnError: true);
    active++;
    try {
      var pos = start;
      while (pos <= end && !gone) {
        final n = min(256 * 1024, end - pos + 1);
        final data = await streamer.read(f.path, f.bytes, pos, n);
        if (gone) break;
        socket.add(data);
        await socket.flush(); // waits while the player isn't reading (paused): no wasted phone reads
        pos += n;
        if (!gone) streamer.readAhead(f.path, f.bytes, pos, 2 << 20);
      }
    } catch (_) {
      // Player went away mid-write.
    } finally {
      active--;
      socket.destroy();
    }
  }

  Future<void> close() => _http.close(force: true);
}
