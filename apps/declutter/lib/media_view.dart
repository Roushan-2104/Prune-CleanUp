import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:phone_link/phone_link.dart';

import 'previews.dart';

/// Small square preview for list rows: the photo itself, or an icon.
/// Photos are copied to the laptop only when their row is on screen.
class FileThumb extends StatelessWidget {
  const FileThumb({super.key, required this.file, required this.previews, this.size = 56});
  final PhoneFile file;
  final PreviewCache? previews;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    Widget box(Widget child) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(width: size, height: size, color: c.surfaceContainerHighest, child: child),
        );
    if (!file.isImage || previews == null) return box(Icon(iconFor(file), color: c.onSurfaceVariant));
    return box(FutureBuilder<File?>(
      future: previews!.get(file),
      builder: (context, snap) => snap.data == null
          ? Icon(Icons.photo_outlined, color: c.onSurfaceVariant)
          : Image.file(snap.data!, fit: BoxFit.cover, cacheWidth: (size * 2).round(), gaplessPlayback: true),
    ));
  }
}

IconData iconFor(PhoneFile f) => f.isVideo
    ? Icons.movie_outlined
    : f.isImage
        ? Icons.photo_outlined
        : f.isAudio
            ? Icons.graphic_eq
            : Icons.description_outlined;

/// Large view of one file: zoomable photo, playable video or audio, or a
/// button to open other files in their usual Windows app.
class MediaView extends StatefulWidget {
  const MediaView({super.key, required this.file, required this.previews, this.height = 320});
  final PhoneFile file;
  final PreviewCache? previews;
  final double height;

  @override
  State<MediaView> createState() => MediaViewState();
}

class MediaViewState extends State<MediaView> {
  Future<File?>? _local;
  Player? _player;

  /// Why playback failed, shown on screen instead of failing silently.
  String? error;

  /// What's happening before playback starts, e.g. "Copying 12.3 MB…".
  String? _status;

  /// The active player (also read by the app's automated UI tests).
  Player? get player => _player;
  VideoController? _video;

  bool get _playable => widget.file.isVideo || widget.file.isAudio;

  @override
  void initState() {
    super.initState();
    // Photos load right away; videos, audio and documents only when asked
    // (they can be large).
    if (widget.file.isImage) _local = widget.previews?.get(widget.file);
  }

  @override
  void didUpdateWidget(MediaView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _disposePlayer();
      _local = widget.file.isImage ? widget.previews?.get(widget.file) : null;
    }
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

  /// Copies the file (asking first if it's big), then plays it.
  Future<void> play() async {
    final f = widget.file;
    if (f.bytes > 200 << 20 && !await _confirmBig()) return;
    setState(() {
      error = null;
      _status = 'Copying ${_mb(f.bytes)} from the phone…';
      _local = widget.previews?.get(f);
    });
    final local = await _local;
    if (!mounted) return;
    if (local == null) {
      setState(() {
        _local = null;
        _status = null;
        error = widget.previews == null
            ? 'Previews are unavailable for this phone.'
            : 'Couldn\'t copy ${f.name} from the phone to play it.';
      });
      return;
    }
    try {
      final player = Player();
      player.stream.error.listen((e) {
        debugPrint('[player] error for ${f.name}: $e');
        if (mounted) setState(() => error = 'The player reported: $e');
      });
      player.stream.playing.listen((p) => debugPrint('[player] ${f.name} playing=$p'));
      player.stream.duration.listen((d) => debugPrint('[player] ${f.name} duration=$d'));
      player.stream.log.listen((l) {
        if (l.level == 'error' || l.level == 'warn') debugPrint('[mpv ${l.level}] ${l.prefix}: ${l.text}');
      });
      setState(() {
        _status = null;
        _player = player;
        _video = f.isVideo ? VideoController(player) : null;
      });
      debugPrint('[player] opening ${local.path} (${local.lengthSync()} bytes)');
      await player.open(Media(local.uri.toString()), play: false);
      await player.play();
    } catch (e) {
      debugPrint('[player] failed for ${f.name}: $e');
      if (mounted) setState(() => error = 'Couldn\'t play ${f.name}: $e');
    }
  }

  /// "This video is 1.2 GB. Copying it to play takes about 40 seconds."
  Future<bool> _confirmBig() async {
    final secs = (widget.file.bytes / (30 << 20)).ceil(); // ~30 MB/s over USB
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Play a big video?'),
        content: Text('${widget.file.name} is ${_mb(widget.file.bytes)}. To play it, Declutter copies it from the phone '
            'first, which takes about $secs seconds. The copy is deleted when Declutter closes.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Copy and play')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _openInWindows() async {
    setState(() => _local = widget.previews?.get(widget.file));
    final f = await _local;
    if (f != null) await Process.run('explorer.exe', [f.path]);
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final frame = BoxDecoration(color: c.surfaceContainerHighest, borderRadius: BorderRadius.circular(10));

    Widget body;
    if (_player != null) {
      // Our own compact controls: the built-in ones don't fit narrow panels.
      body = Column(children: [
        Expanded(
          child: _video != null
              ? Video(controller: _video!, controls: NoVideoControls)
              : Center(child: Icon(Icons.graphic_eq, size: 56, color: c.onSurfaceVariant)),
        ),
        PlayerBar(player: _player!),
      ]);
    } else if (widget.file.isImage) {
      body = FutureBuilder<File?>(
        future: _local,
        builder: (context, snap) => snap.connectionState != ConnectionState.done
            ? const Center(child: CircularProgressIndicator())
            : snap.data == null
                ? const Center(child: Text('Preview not available'))
                : InteractiveViewer(maxScale: 6, child: Image.file(snap.data!, fit: BoxFit.contain)),
      );
    } else if (_playable) {
      body = Center(
        child: _local == null
            ? FilledButton.icon(
                onPressed: play,
                icon: const Icon(Icons.play_arrow),
                label: Text(widget.file.isVideo ? 'Play video' : 'Play audio'),
              )
            : Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                Text(_status ?? 'Getting ready…'),
              ]),
      );
    } else {
      body = Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(iconFor(widget.file), size: 48, color: c.onSurfaceVariant),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _openInWindows,
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open in its usual app'),
          ),
        ]),
      );
    }
    if (error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline, color: c.error),
            const SizedBox(height: 8),
            Text(error!, textAlign: TextAlign.center, style: TextStyle(color: c.error)),
            TextButton(onPressed: play, child: const Text('Try again')),
          ]),
        ),
      );
    }
    return Container(height: widget.height, decoration: frame, clipBehavior: Clip.antiAlias, child: body);
  }
}

String _mb(int bytes) => bytes >= 1 << 30
    ? '${(bytes / (1 << 30)).toStringAsFixed(1)} GB'
    : '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';

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
          return Row(children: [
            IconButton(
              tooltip: s.playing ? 'Pause' : 'Play',
              onPressed: () => s.completed ? player.seek(Duration.zero).then((_) => player.play()) : player.playOrPause(),
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
          ]);
        },
      ),
    );
  }
}
