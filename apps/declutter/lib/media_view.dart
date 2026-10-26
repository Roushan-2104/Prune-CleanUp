import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:phone_link/phone_link.dart';

import 'dev_log.dart';
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
              : Image.file(
                  snap.data!,
                  fit: BoxFit.cover,
                  // Screenshots carry what matters at the top: the chat name, "Payment Successful".
                  alignment: fill ? Alignment.topCenter : Alignment.center,
                  cacheWidth: cache,
                  gaplessPlayback: true,
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

/// Files Windows would run rather than show: programs, scripts, shortcuts,
/// installers and macro-enabled documents.
bool isRunnable(String path) {
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  return const {
    'exe', 'com', 'scr', 'pif', 'bat', 'cmd', 'ps1', 'psm1', 'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh', 'hta',
    'msi', 'msp', 'msix', 'appx', 'appinstaller', 'application', 'lnk', 'url', 'reg', 'jar', 'cpl', 'dll', 'sys',
    'inf', 'sct', 'chm', 'gadget', 'iso', 'img', 'vhd', 'vhdx', 'docm', 'dotm', 'xlsm', 'xltm', 'xlam', 'pptm',
    'potm', 'ppam', 'sldm',
  }.contains(ext);
}

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
    if (isRunnable(f.path)) {
      // A program or script from the phone is never run from here: show it
      // in its folder instead, so opening it is a deliberate choice.
      await Process.run(explorer, ['/select,', f.path]);
      if (mounted) {
        setState(() => error = 'Prune does not open programs or scripts. It is shown in its folder instead.');
      }
      return;
    }
    markFromInternet(f.path);
    await Process.run(explorer, [f.path]);
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
                // Held at most 4096 px a side, whatever size the file claims.
                child: Image(
                  image: ResizeImage(FileImage(snap.data!),
                      width: 4096, height: 4096, policy: ResizeImagePolicy.fit, allowUpscaling: false),
                  fit: BoxFit.contain,
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
              TextButton(onPressed: play, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    return Container(height: widget.height, decoration: frame, clipBehavior: Clip.antiAlias, child: body);
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
