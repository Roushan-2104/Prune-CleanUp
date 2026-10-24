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
  State<MediaView> createState() => _MediaViewState();
}

class _MediaViewState extends State<MediaView> {
  Future<File?>? _local;
  Player? _player;
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
  void didUpdateWidget(MediaView old) {
    super.didUpdateWidget(old);
    if (old.file.path != widget.file.path) {
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

  Future<void> _play() async {
    setState(() => _local = widget.previews?.get(widget.file));
    final f = await _local;
    if (f == null || !mounted) return;
    final player = Player();
    setState(() {
      _player = player;
      _video = widget.file.isVideo ? VideoController(player) : null;
    });
    await player.open(Media(f.path));
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
      body = _video != null
          ? Video(controller: _video!)
          : _AudioControls(player: _player!);
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
                onPressed: _play,
                icon: const Icon(Icons.play_arrow),
                label: Text(widget.file.isVideo ? 'Play video' : 'Play audio'),
              )
            : const CircularProgressIndicator(),
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
    return Container(height: widget.height, decoration: frame, clipBehavior: Clip.antiAlias, child: body);
  }
}

class _AudioControls extends StatelessWidget {
  const _AudioControls({required this.player});
  final Player player;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: StreamBuilder<bool>(
        stream: player.stream.playing,
        builder: (context, snap) {
          final playing = snap.data ?? false;
          return Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.graphic_eq, size: 48),
            IconButton.filled(
              iconSize: 32,
              onPressed: player.playOrPause,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            ),
          ]);
        },
      ),
    );
  }
}
