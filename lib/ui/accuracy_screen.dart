import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../accuracy/accuracy.dart';
import '../app_state.dart';
import '../scan/verdict.dart';

Future<LabelStore> _openLabels() async =>
    LabelStore.load(File('${(await getApplicationSupportDirectory()).path}/accuracy_labels.json'));

String _pct(double? v) => v == null ? '—' : '${(v * 100).round()}%';

/// Results of the accuracy test, plus the button to label more photos.
class AccuracyScreen extends StatefulWidget {
  const AccuracyScreen({super.key, required this.state});
  final AppState state;

  @override
  State<AccuracyScreen> createState() => _AccuracyScreenState();
}

class _AccuracyScreenState extends State<AccuracyScreen> {
  LabelStore? _store;

  @override
  void initState() {
    super.initState();
    _openLabels().then((s) async {
      if (widget.state.status == ScanStatus.done && s.upgrade(_predictions)) await s.save();
      if (mounted) setState(() => _store = s);
    });
  }

  Map<String, Verdict> get _predictions =>
      {for (final i in widget.state.items) i.asset.id: i.verdict};

  Future<void> _labelMore() async {
    final store = _store!;
    final sample = pickSample(
      predictions: _predictions,
      galleryIds: widget.state.gallery.keys.toList(),
      alreadyLabeled: store.labels.keys.toSet(),
    );
    if (sample.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No unlabelled photos left — run a scan first.')));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LabelingScreen(state: widget.state, store: store, ids: sample),
    ));
    setState(() {});
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear all your answers?'),
        content: const Text('The accuracy scores start again from zero. Your photos are not touched.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    _store!.labels.clear();
    await _store!.save();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    if (store == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (widget.state.status != ScanStatus.done) {
      return Scaffold(
        appBar: AppBar(title: const Text('Accuracy test')),
        body: const Center(child: Text('Run a scan first, then come back here.')),
      );
    }

    final report = evaluate(store.labels, _predictions, widget.state.gallery.keys.toSet());
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Accuracy test'), actions: [
        if (store.labels.isNotEmpty)
          IconButton(tooltip: 'Clear answers', onPressed: _reset, icon: const Icon(Icons.restart_alt)),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('You judge a mix of photos without seeing the app\'s guess. '
            'Your answers stay on this phone and are only used to measure accuracy.'),
        const SizedBox(height: 16),
        if (report.labeled == 0)
          const Text('No answers yet.')
        else ...[
          _Headline(report: report),
          const SizedBox(height: 16),
          Text('By category', style: theme.textTheme.titleMedium),
          for (final MapEntry(key: c, value: s) in report.perCategory.entries)
            Card(
              child: ListTile(
                title: Text(c.label),
                subtitle: Text([
                  '${s.correct} of ${s.flagged} right (${_pct(s.accuracy)})',
                  if (s.sureFlagged > 0) '"Sure": ${s.sureCorrect} of ${s.sureFlagged} (${_pct(s.sureAccuracy)})',
                  if (s.wrongKind > 0) '${s.wrongKind} junk but wrong type',
                  if (s.goodPhotoFlagged > 0) '⚠ ${s.goodPhotoFlagged} good photos flagged',
                ].join('\n')),
                isThreeLine: true,
              ),
            ),
          const SizedBox(height: 8),
          Text('Not flagged by the app', style: theme.textTheme.titleMedium),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(report.missedTotal == 0
                ? 'You checked ${report.unflaggedChecked} unflagged photos — no junk was missed.'
                : 'You checked ${report.unflaggedChecked} unflagged photos — '
                    '${report.missedTotal} were junk the app missed: '
                    '${report.missed.entries.map((e) => '${e.value} ${e.key.text.toLowerCase()}').join(', ')}.'),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _labelMore,
          icon: const Icon(Icons.fact_check_outlined),
          label: Text(report.labeled == 0 ? 'Start: judge 50 photos' : 'Judge 50 more photos'),
        ),
      ]),
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.report});
  final AccuracyReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sure = report.sureAccuracy;
    final onTarget = sure != null && sure >= 0.98;
    return Card(
      color: onTarget ? Colors.green.withValues(alpha: 0.15) : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('"Sure junk" accuracy', style: theme.textTheme.titleMedium),
          Text(_pct(sure), style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold)),
          Text('Target 98% · based on ${report.sureFlagged} pre-selected photos you judged'),
          const SizedBox(height: 8),
          Text(report.goodPhotosFlagged == 0
              ? '✓ No good photos were flagged'
              : '⚠ ${report.goodPhotosFlagged} good photos were flagged '
                  '(${report.goodPhotosFlaggedSure} of them pre-selected)'),
          Text('${report.labeled} photos judged in total'),
        ]),
      ),
    );
  }
}

/// One photo at a time; tap what it really is. Answers save as you go.
class LabelingScreen extends StatefulWidget {
  const LabelingScreen({super.key, required this.state, required this.store, required this.ids});
  final AppState state;
  final LabelStore store;
  final List<String> ids;

  @override
  State<LabelingScreen> createState() => _LabelingScreenState();
}

class _LabelingScreenState extends State<LabelingScreen> {
  var _index = 0;

  Future<void> _answer(TrueLabel? label) async {
    final id = widget.ids[_index];
    if (label != null) {
      widget.store.labels[id] = label;
      await widget.store.save();
    }
    if (!mounted) return;
    if (_index + 1 >= widget.ids.length) {
      Navigator.of(context).pop();
    } else {
      setState(() => _index++);
    }
  }

  Widget _image(AssetEntity asset) => AssetEntityImage(asset,
      isOriginal: false, thumbnailSize: const ThumbnailSize.square(1200), fit: BoxFit.contain);

  @override
  Widget build(BuildContext context) {
    final id = widget.ids[_index];
    final asset = widget.state.gallery[id];
    final current = widget.store.labels[id];
    // A near-copy looks like a good photo on its own, so show what it was matched with.
    final match = widget.state.items.where((i) => i.asset.id == id).firstOrNull?.match;

    return Scaffold(
      appBar: AppBar(
        title: Text('Photo ${_index + 1} of ${widget.ids.length}'),
        actions: [
          if (_index > 0)
            TextButton(onPressed: () => setState(() => _index--), child: const Text('Back')),
        ],
      ),
      body: Column(children: [
        LinearProgressIndicator(value: (_index + 1) / widget.ids.length),
        Expanded(
          child: asset == null
              ? const Center(child: Text('This photo no longer exists'))
              : Padding(
                  padding: const EdgeInsets.all(8),
                  child: match == null
                      ? _image(asset)
                      : Row(children: [
                          Expanded(child: Column(children: [
                            const Text('This photo', style: TextStyle(fontWeight: FontWeight.bold)),
                            Expanded(child: _image(asset)),
                          ])),
                          const SizedBox(width: 8),
                          Expanded(child: Column(children: [
                            const Text('Compare with'),
                            Expanded(child: _image(match)),
                          ])),
                        ]),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(match == null
              ? 'What is this really?'
              : 'Is the left photo a copy / near-copy of the right one? '
                  'If yes, tap "Duplicate / similar".'),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
              for (final l in TrueLabel.values)
                ChoiceChip(
                  label: Text(l.text),
                  selected: current == l,
                  avatar: l == TrueLabel.keep ? const Icon(Icons.favorite, size: 18) : null,
                  onSelected: (_) => _answer(l),
                ),
              ActionChip(label: const Text('Not sure — skip'), onPressed: () => _answer(null)),
            ]),
          ),
        ),
      ]),
    );
  }
}
