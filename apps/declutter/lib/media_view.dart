import 'dart:io';
import 'dart:math' show max;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:phone_link/phone_link.dart';

import 'dev_log.dart';
import 'previews.dart';
import 'review_media.dart';

/// Small square preview for list rows: the photo itself, a frame from the
/// video, or an icon. Fetched only when the row is on screen.
class FileThumb extends StatefulWidget {
  const FileThumb({super.key, required this.file, required this.media, this.size = 56, this.fill = false});
  final PhoneFile file;
  final ReviewMedia? media;
  final double size;

  /// Fill the space given instead of a [size] square (cards in a grid).
  final bool fill;

  @override
  State<FileThumb> createState() => _FileThumbState();
}

class _FileThumbState extends State<FileThumb> {
  // Asked for once per file, not on every redraw (that restarted the
  // request each time and made thumbnails flicker).
  Future<File?>? _image;
  Future<Uint8List?>? _frame;
  Future<Uint8List?>? _document;

  void _ask() {
    final m = widget.media, f = widget.file;
    _image = m != null && f.isImage ? m.previews.get(f) : null;
    _frame = m != null && f.isVideo ? m.thumbnail(f) : null;
    _document = m != null && isDocument(f) ? m.documentPreview(f) : null;
  }

  @override
  void initState() {
    super.initState();
    _ask();
  }

  @override
  void didUpdateWidget(FileThumb old) {
    super.didUpdateWidget(old);
    if (old.file.path != widget.file.path || old.media != widget.media) _ask();
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file, size = widget.size, fill = widget.fill;
    final c = Theme.of(context).colorScheme;
    final cache = fill ? 520 : (size * 2).round();
    Widget box(Widget child) => ClipRRect(
      borderRadius: BorderRadius.circular(fill ? 2 : 8),
      child: Container(
        width: fill ? double.infinity : size,
        height: fill ? double.infinity : size,
        color: c.surfaceContainerHighest,
        child: child,
      ),
    );
    if (_image case final image?) {
      return box(
        FutureBuilder<File?>(
          future: image,
          builder: (context, snap) => snap.data == null
              ? Icon(Icons.photo_outlined, color: c.onSurfaceVariant)
              : Image(
                  image: SafeFileImage(snap.data!, width: cache),
                  fit: BoxFit.cover,
                  // Screenshots carry what matters at the top: the chat name, "Payment Successful".
                  alignment: fill ? Alignment.topCenter : Alignment.center,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, _) => _NoPreview(error: error, small: !fill),
                ),
        ),
      );
    }
    if (_frame case final frame?) {
      return box(
        FutureBuilder<Uint8List?>(
          future: frame,
          builder: (context, snap) => Stack(
            fit: StackFit.expand,
            children: [
              if (snap.data != null)
                Image.memory(snap.data!, fit: BoxFit.cover, cacheWidth: cache, gaplessPlayback: true)
              else
                Icon(Icons.movie_outlined, color: c.onSurfaceVariant),
              const Align(
                alignment: Alignment.bottomRight,
                child: Icon(Icons.play_circle, size: 18, color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }
    if (_document case final doc?) {
      return box(
        FutureBuilder<Uint8List?>(
          future: doc,
          builder: (context, snap) => snap.data == null
              ? Icon(iconFor(file), color: c.onSurfaceVariant)
              : Padding(
                  // A page or an icon: shown whole, never cropped.
                  padding: EdgeInsets.all(fill ? 10 : 4),
                  child: Image.memory(snap.data!, fit: BoxFit.contain, cacheWidth: cache, gaplessPlayback: true),
                ),
        ),
      );
    }
    return box(Icon(iconFor(file), color: c.onSurfaceVariant));
  }
}

/// Anything that isn't a photo, video or audio: documents, installers,
/// archives… shown by [ReviewMedia.documentPreview].
bool isDocument(PhoneFile f) => !f.isImage && !f.isVideo && !f.isAudio;

/// The lower-case extension of [path] as Windows sees it (trailing dots
/// and spaces are ignored, as Windows ignores them), or '' if none.
String _extension(String path) {
  final name = path.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'[. ]+$'), '');
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/// The only kinds of file "Open in its usual app" will open: documents,
/// contacts and zips, all opened in apps that respect the
/// downloaded-from-the-internet mark. Everything else is only shown in a
/// folder, so opening it there is a deliberate choice.
bool opensInUsualApp(String path) => const {
  'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods', 'odp', 'txt', 'csv', 'rtf', 'vcf', 'zip',
}.contains(_extension(path));

/// Shortcut-like files Windows may follow just by drawing them in a folder
/// (their icon or target can point at another computer), so Prune does not
/// even show them in one.
bool isShortcutLike(String path) => const {
  'lnk', 'url', 'library-ms', 'searchconnector-ms', 'scf',
}.contains(_extension(path));

/// Files Windows would run, or that can reach out to the internet, rather
/// than simply show: programs, scripts, shortcuts, installers,
/// macro-enabled documents, and web pages, mail and drawings that can load
/// remote content. Used to explain why a file is only shown in its folder.
bool isRunnable(String path) => const {
  'exe', 'com', 'scr', 'pif', 'bat', 'cmd', 'ps1', 'psm1', 'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh', 'wsc', 'hta',
  'py', 'pyw', 'jnlp', 'msc', 'diagcab', 'theme', 'themepack', 'deskthemepack', 'library-ms',
  'searchconnector-ms', 'settingcontent-ms', 'appref-ms', 'rdp', 'scf', 'xll', 'mht', 'mhtml', 'html', 'htm',
  'xhtml', 'svg', 'eml', 'xml',
  'msi', 'msp', 'msix', 'appx', 'appinstaller', 'application', 'lnk', 'url', 'reg', 'jar', 'cpl', 'dll', 'sys',
  'inf', 'sct', 'chm', 'gadget', 'iso', 'img', 'vhd', 'vhdx', 'docm', 'dotm', 'xlsm', 'xltm', 'xlam', 'pptm',
  'potm', 'ppam', 'sldm',
}.contains(_extension(path));

/// Marks a copied file as downloaded from the internet (its
/// Zone.Identifier, as a browser would), so Windows' own SmartScreen and
/// Office Protected View still warn before anything in it runs.
void markFromInternet(String path) {
  try {
    File('$path:Zone.Identifier').writeAsStringSync('[ZoneTransfer]\r\nZoneId=3\r\n');
  } catch (_) {
    // Not NTFS (e.g. a FAT USB drive): nothing to mark.
  }
}

/// Photos bigger than this are not decoded: a small file can claim to be
/// enormous and make the decoder ask for gigabytes of memory. Memory follows
/// the pixel count, so that is the real limit; the side limit is only PNG's
/// practical bound, and long scrolling screenshots of any length still show.
const maxImageSide = 65535;
const maxImagePixels = 50 * 1000 * 1000;

/// JPEGs are decoded straight to a smaller size (an eighth at most), so
/// genuine 108 and 200 megapixel phone photos stay viewable.
const maxJpegSide = 20000;
const maxJpegPixels = 260 * 1000 * 1000;

/// Whether an image of [width] x [height] is too big to decode safely.
bool tooBigToShow(int width, int height, {bool jpeg = false}) =>
    width > (jpeg ? maxJpegSide : maxImageSide) ||
    height > (jpeg ? maxJpegSide : maxImageSide) ||
    width * height > (jpeg ? maxJpegPixels : maxImagePixels);

/// Thrown instead of decoding an image whose claimed size is too big.
class ImageTooLarge implements Exception {
  ImageTooLarge(this.width, this.height);
  final int width, height;
  @override
  String toString() => 'Too large to preview ($width x $height pixels)';
}

/// A photo from a local file, decoded at most [width] wide or [maxSide] on
/// its longest side, and never decoded at all if its header claims a size
/// beyond [tooBigToShow] (see [ImageTooLarge]). The size is read from the
/// header before any pixels, and the file is read only once.
class SafeFileImage extends ImageProvider<SafeFileImage> {
  const SafeFileImage(this.file, {this.width, this.maxSide});
  final File file;
  final int? width;
  final int? maxSide;

  @override
  Future<SafeFileImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(SafeFileImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1, debugLabel: file.path);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final raf = await file.open();
    final Uint8List head;
    try {
      head = await raf.read(3);
    } finally {
      await raf.close();
    }
    if (head.isEmpty) throw StateError('${file.path} is empty');
    final jpeg = head.length == 3 && head[0] == 0xFF && head[1] == 0xD8 && head[2] == 0xFF;
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    return decode(buffer, getTargetSize: (w, h) {
      if (tooBigToShow(w, h, jpeg: jpeg)) throw ImageTooLarge(w, h);
      return targetSize(w, h, width: width, maxSide: maxSide);
    });
  }

  /// The size to decode a [w] x [h] image at: never larger than it is.
  static ui.TargetImageSize targetSize(int w, int h, {int? width, int? maxSide}) {
    if (width != null && width < w) return ui.TargetImageSize(width: width);
    if (maxSide != null && max(w, h) > maxSide) {
      final scale = maxSide / max(w, h);
      return ui.TargetImageSize(width: max(1, (w * scale).round()), height: max(1, (h * scale).round()));
    }
    return const ui.TargetImageSize();
  }

  @override
  bool operator ==(Object other) =>
      other is SafeFileImage && other.file.path == file.path && other.width == width && other.maxSide == maxSide;

  @override
  int get hashCode => Object.hash(file.path, width, maxSide);
}

/// A file name as shown on screen, with invisible direction marks made
/// visible: a name with U+202E before "fdp.exe" would otherwise display as "…exe.pdf".
String displayName(String name) => name.replaceAll(RegExp(r'[\u200e\u200f\u202a-\u202e\u2066-\u2069]'), '\uFFFD');

/// A file's kind at a glance, while (or instead of) its preview loads.
IconData iconFor(PhoneFile f) {
  if (f.isVideo) return Icons.movie_outlined;
  if (f.isImage) return Icons.photo_outlined;
  if (f.isAudio) return Icons.graphic_eq;
  final dot = f.name.lastIndexOf('.');
  return switch (dot < 0 ? '' : f.name.substring(dot + 1).toLowerCase()) {
    'apk' || 'xapk' || 'apks' => Icons.android,
    'pdf' => Icons.picture_as_pdf_outlined,
    'doc' || 'docx' || 'odt' || 'rtf' || 'txt' => Icons.article_outlined,
    'xls' || 'xlsx' || 'csv' || 'ods' => Icons.table_chart_outlined,
    'ppt' || 'pptx' || 'odp' => Icons.slideshow_outlined,
    'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.folder_zip_outlined,
    'vcf' => Icons.contact_page_outlined,
    _ => Icons.description_outlined,
  };
}

/// Five frames spread across a video, so you can often decide without
/// pressing Play. Tap a frame to play from there.
class Filmstrip extends StatelessWidget {
  const Filmstrip({super.key, required this.file, required this.media, this.onTapFrame});
  final PhoneFile file;
  final ReviewMedia media;
  final void Function(double fraction)? onTapFrame;

  static const at = [0.05, 0.27, 0.5, 0.73, 0.95];

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return SizedBox(
      height: 64,
      child: FutureBuilder<List<Uint8List>>(
        future: media.filmstrip(file),
        builder: (context, snap) {
          final frames = snap.data;
          if (frames == null) {
            return Center(
              child: Text('Getting frames…', style: TextStyle(color: c.onSurfaceVariant)),
            );
          }
          if (frames.isEmpty) return const SizedBox.shrink();
          return Row(
            children: [
              for (final (i, frame) in frames.indexed) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(
                  child: InkWell(
                    onTap: onTapFrame == null ? null : () => onTapFrame!(at[i]),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.memory(frame, fit: BoxFit.cover, height: 64, gaplessPlayback: true),
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Large view of one file: zoomable photo, playable video or audio, or a
/// button to open other files in their usual Windows app.
class MediaView extends StatefulWidget {
  const MediaView({super.key, required this.file, required this.media, this.height = 320});
  final PhoneFile file;
  final ReviewMedia? media;
  final double height;

  @override
  State<MediaView> createState() => MediaViewState();
}

class MediaViewState extends State<MediaView> {
  Future<File?>? _local;
  Player? _player;

  /// Why playback failed, shown on screen instead of failing silently.
  String? error;

  /// What's happening before playback starts, e.g. "Getting the video…".
  String? _status;

  Player? get player => _player;
  VideoController? _video;

  bool get _playable => widget.file.isVideo || widget.file.isAudio;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(MediaView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _disposePlayer();
      error = null;
      _prepare();
    }
  }

  /// Photos load right away; videos and audio get their first seconds
  /// fetched in the background so Play starts instantly.
  void _prepare() {
    _local = null;
    if (widget.file.isImage) _local = widget.media?.previews.get(widget.file);
    if (_playable) widget.media?.warmUp(widget.file);
  }

  void _disposePlayer() {
    _player?.dispose();
    _player = null;
    _video = null;
  }

  @override
  void dispose() {
    _disposePlayer();
    super.dispose();
  }

  /// Plays the file: small ones are fetched whole, big ones streamed from
  /// the phone. [from] is a fraction of the length to start at (0–1).
  Future<void> play({double from = 0}) async {
    final f = widget.file, m = widget.media;
    if (_player != null) {
      final d = _player!.state.duration;
      if (d > Duration.zero) await _player!.seek(d * from);
      await _player!.play();
      return;
    }
    setState(() {
      error = null;
      _status = f.bytes <= ReviewMedia.smallFile ? 'Getting ${_mb(f.bytes)} from the phone…' : 'Starting the stream…';
      _local = Future.value(null); // shows the progress state
    });
    final String? src;
    try {
      src = m == null ? null : await m.playableSource(f);
    } on NotMedia catch (e) {
      if (mounted) {
        setState(() {
          _local = null;
          _status = null;
          error = '$e';
        });
      }
      return;
    }
    if (!mounted) return;
    if (src == null) {
      setState(() {
        _local = null;
        _status = null;
        error = m == null ? 'Previews are unavailable for this phone.' : 'Couldn\'t get ${f.name} from the phone.';
      });
      return;
    }
    try {
      final player = safePlayer();
      await hardenPlayer(player);
      player.stream.error.listen((e) {
        devLog('[player] error for ${f.name}: $e');
        if (mounted) setState(() => error = 'The player reported: $e');
      });
      player.stream.playing.listen((p) => devLog('[player] ${f.name} playing=$p'));
      player.stream.log.listen((l) {
        if (l.level == 'error' || l.level == 'warn') devLog('[mpv ${l.level}] ${l.prefix}: ${l.text}');
      });
      setState(() {
        _status = null;
        _player = player;
        _video = f.isVideo ? VideoController(player) : null;
      });
      devLog('[player] opening ${f.bytes <= ReviewMedia.smallFile ? 'local copy' : 'stream'} of ${f.name}');
      await player.open(Media(src), play: false);
      if (from > 0) {
        final d = await player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 10));
        await player.seek(d * from);
      }
      await player.play();
    } catch (e) {
      devLog('[player] failed for ${f.name}: $e');
      if (mounted) setState(() => error = 'Couldn\'t play ${f.name}: $e');
    }
  }

  Future<void> _openInWindows() async {
    setState(() => _local = widget.media?.previews.get(widget.file));
    final f = await _local;
    if (f == null) return;
    final explorer = '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\explorer.exe';
    if (opensInUsualApp(f.path)) {
      markFromInternet(f.path); // already marked when copied; kept as a second guard
      await Process.run(explorer, [f.path]);
      return;
    }
    if (isShortcutLike(f.path)) {
      // Explorer can follow a shortcut just by drawing it, so it isn't shown at all.
      if (mounted) {
        setState(() => error = 'This is a shortcut. Prune does not open or show shortcuts from a phone.');
      }
      return;
    }
    // Anything else is never opened from here: it is shown alone in a new
    // folder instead, so opening it is a deliberate choice and nothing else
    // from the phone sits next to it.
    final File alone;
    try {
      alone = PreviewCache.aloneInFolder(f);
    } catch (_) {
      if (mounted) setState(() => error = 'Couldn\'t show ${displayName(widget.file.name)} in a folder.');
      return;
    }
    await Process.run(explorer, ['/select,', alone.path]);
    if (mounted) {
      setState(() => error = isRunnable(f.path)
          ? 'Prune does not open programs or scripts. It is shown in its folder instead.'
          : 'Prune opens only documents. This file is shown in its folder instead.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final frame = BoxDecoration(color: c.surfaceContainerHighest, borderRadius: BorderRadius.circular(10));

    Widget body;
    if (_player != null) {
      // Our own compact controls: the built-in ones don't fit narrow panels.
      body = Column(
        children: [
          Expanded(
            child: _video != null
                ? Video(controller: _video!, controls: NoVideoControls)
                : Center(child: Icon(Icons.graphic_eq, size: 56, color: c.onSurfaceVariant)),
          ),
          PlayerBar(player: _player!),
        ],
      );
    } else if (widget.file.isImage) {
      body = FutureBuilder<File?>(
        future: _local,
        builder: (context, snap) => snap.connectionState != ConnectionState.done
            ? const Center(child: CircularProgressIndicator())
            : snap.data == null
            ? const Center(child: Text('Preview not available'))
            : InteractiveViewer(
                maxScale: 6,
                // Held at most 4096 px a side, and not decoded at all if
                // the file claims a size too big to decode safely.
                child: Image(
                  image: SafeFileImage(snap.data!, maxSide: 4096),
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, _) => Center(child: _NoPreview(error: error)),
                ),
              ),
      );
    } else if (_playable) {
      body = Center(
        child: _local == null
            ? OutlinedButton.icon(
                // Not violet: in Prune violet only means "will be removed".
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.onSurface,
                  side: BorderSide(color: c.onSurface),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                ),
                onPressed: play,
                icon: const Icon(Icons.play_arrow),
                label: Text(widget.file.isVideo ? 'Play video' : 'Play audio'),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(_status ?? 'Getting ready…'),
                ],
              ),
      );
    } else {
      // A document or installer: its preview (first page, app icon…) large,
      // and a way to open it properly.
      body = Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: FileThumb(key: ValueKey(widget.file.path), file: widget.file, media: widget.media, fill: true),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: OutlinedButton.icon(
              onPressed: _openInWindows,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open in its usual app'),
            ),
          ),
        ],
      );
    }
    if (error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: c.error),
              const SizedBox(height: 8),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.error),
              ),
              _playable
                  ? TextButton(onPressed: play, child: const Text('Try again'))
                  : TextButton(onPressed: () => setState(() => error = null), child: const Text('OK')),
            ],
          ),
        ),
      );
    }
    return Container(height: widget.height, decoration: frame, clipBehavior: Clip.antiAlias, child: body);
  }
}

/// Shown in place of a photo that couldn't be shown: the photo icon, and a
/// short note when there is room for one.
class _NoPreview extends StatelessWidget {
  const _NoPreview({required this.error, this.small = false});
  final Object error;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final note = error is ImageTooLarge ? 'Too large to preview' : 'Preview not available';
    final icon = Icon(Icons.photo_outlined, color: c.onSurfaceVariant);
    if (small) return Tooltip(message: note, child: Center(child: icon));
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(height: 6),
            Text(note, textAlign: TextAlign.center, style: TextStyle(color: c.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

String _mb(int bytes) =>
    bytes >= 1 << 30 ? '${(bytes / (1 << 30)).toStringAsFixed(1)} GB' : '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';

/// Play/pause, a progress bar you can drag, and "0:03 / 0:15".
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key, required this.player});
  final Player player;

  static String _t(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: StreamBuilder<Duration>(
        stream: player.stream.position,
        builder: (context, _) {
          final s = player.state;
          final total = s.duration.inMilliseconds;
          return Row(
            children: [
              IconButton(
                tooltip: s.playing ? 'Pause' : 'Play',
                onPressed: () =>
                    s.completed ? player.seek(Duration.zero).then((_) => player.play()) : player.playOrPause(),
                icon: Icon(s.playing ? Icons.pause : Icons.play_arrow),
              ),
              Expanded(
                child: Slider(
                  value: total == 0 ? 0 : (s.position.inMilliseconds / total).clamp(0.0, 1.0),
                  onChanged: total == 0 ? null : (v) => player.seek(Duration(milliseconds: (v * total).round())),
                ),
              ),
              Text('${_t(s.position)} / ${_t(s.duration)}', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(width: 8),
            ],
          );
        },
      ),
    );
  }
}
