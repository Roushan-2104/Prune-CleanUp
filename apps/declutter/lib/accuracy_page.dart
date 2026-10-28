import 'dart:math' as math;

import 'package:declutter_engine/declutter_engine.dart' hide shortDate;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phone_link/phone_link.dart';

import 'media_view.dart';
import 'phone_session.dart';
import 'review_media.dart';
import 'review_page.dart' show shortDate, shortReason;
import 'theme.dart';

/// How often Prune's "sure" picks are right, measured by the user: a random
/// sample from each group, one at a time — "yes, remove it" or "no, I'd
/// keep it" — then the share that was right, per group.
///
/// Nothing on the phone changes; answers only count, they don't tick or
/// untick anything.
class AccuracyPage extends StatefulWidget {
  const AccuracyPage({super.key, required this.session, this.perGroup = 15});
  final PhoneSession session;
  final int perGroup;

  @override
  State<AccuracyPage> createState() => _AccuracyPageState();
}

enum _Answer { right, wrong, unsure }

class _AccuracyPageState extends State<AccuracyPage> {
  late final ReviewMedia? media =
      widget.session.serial == null ? null : ReviewMedia(widget.session.adb, widget.session.serial!);
  late final Map<String, PhoneFile> files = {for (final f in widget.session.summary!.files) f.path: f};

  /// The sample: up to [AccuracyPage.perGroup] random sure picks per group.
  late final List<MapEntry<String, FileVerdict>> sample = () {
    final r = math.Random();
    final byGroup = <JunkCategory, List<MapEntry<String, FileVerdict>>>{};
    for (final e in widget.session.suggestions.entries) {
      if (e.value.verdict.tier != Tier.sure || !files.containsKey(e.key)) continue;
      (byGroup[e.value.verdict.category] ??= []).add(e);
    }
    return [
      for (final list in byGroup.values) ...(list..shuffle(r)).take(widget.perGroup),
    ]..shuffle(r);
  }();

  final answers = <String, _Answer>{};
  int index = 0;
  bool finished = false;

  void answer(_Answer a) {
    if (finished || index >= sample.length) return;
    setState(() {
      answers[sample[index].key] = a;
      index++;
      if (index >= sample.length) finished = true;
    });
  }

  @override
  void dispose() {
    media?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyY): () => answer(_Answer.right),
        const SingleActivator(LogicalKeyboardKey.keyN): () => answer(_Answer.wrong),
        const SingleActivator(LogicalKeyboardKey.keyS): () => answer(_Answer.unsure),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            finished ? Navigator.of(context).maybePop() : setState(() => finished = true),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              _Header(
                onBack: () => Navigator.of(context).maybePop(),
                done: index,
                total: sample.length,
                finished: finished,
              ),
              Expanded(
                child: sample.isEmpty
                    ? const Center(
                        child: Text('Nothing to check: Prune has no sure picks on this phone yet.',
                            style: TextStyle(color: Tone.muted)),
                      )
                    : finished
                        ? _Results(sample: sample, answers: answers)
                        : _Question(
                            key: ValueKey(index),
                            entry: sample[index],
                            file: files[sample[index].key]!,
                            media: media,
                            onAnswer: answer,
                            onFinish: () => setState(() => finished = true),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onBack, required this.done, required this.total, required this.finished});
  final VoidCallback onBack;
  final int done, total;
  final bool finished;

  @override
  Widget build(BuildContext context) => Container(
        height: 68,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: const BoxDecoration(
          color: Tone.paper,
          border: Border(bottom: BorderSide(color: Tone.rule, width: 2)),
        ),
        child: Row(
          children: [
            IconButton(tooltip: 'Back (Esc)', icon: const Icon(Icons.arrow_back, color: Tone.ink), onPressed: onBack),
            const SizedBox(width: 8),
            const Text('Accuracy check', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(width: 24),
            if (!finished && total > 0) ...[
              SizedBox(
                width: 260,
                child: LinearProgressIndicator(value: done / total, minHeight: 4, color: Tone.ink),
              ),
              const SizedBox(width: 12),
              Text('$done of $total', style: Typed.factMuted),
            ],
          ],
        ),
      );
}

/// One sure pick, large, with what Prune thinks and why.
class _Question extends StatelessWidget {
  const _Question({
    super.key,
    required this.entry,
    required this.file,
    required this.media,
    required this.onAnswer,
    required this.onFinish,
  });
  final MapEntry<String, FileVerdict> entry;
  final PhoneFile file;
  final ReviewMedia? media;
  final void Function(_Answer) onAnswer;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final v = entry.value.verdict;
    final match = entry.value.matchPath == null ? null : files(context)[entry.value.matchPath];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (match != null) ...[
                      const Text('Kept', style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      MediaView(file: match, media: media, height: 220),
                      const SizedBox(height: 12),
                      const Text('Prune would remove this copy', style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      MediaView(file: file, media: media, height: 220),
                    ] else
                      MediaView(file: file, media: media, height: 480),
                  ],
                ),
              ),
              const SizedBox(width: 28),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(v.label ?? v.category.label, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    SelectableText(displayName(file.name), style: Typed.factBold),
                    Text(file.folder, style: const TextStyle(fontSize: 12, color: Tone.muted)),
                    Text('${formatBytes(file.bytes)} · ${shortDate(file.modifiedSec)}', style: Typed.factMuted),
                    const SizedBox(height: 8),
                    Text(shortReason(v), style: Typed.fact),
                    const SizedBox(height: 18),
                    const Text('Should this go?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    const Text('Answer as if you were cleaning your own phone.', style: TextStyle(color: Tone.muted)),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: () => onAnswer(_Answer.right), child: const Text('Yes, remove it  (Y)')),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Tone.ink,
                        side: const BorderSide(color: Tone.ink),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      ),
                      onPressed: () => onAnswer(_Answer.wrong),
                      child: const Text('No, I\'d keep it  (N)'),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        TextButton(onPressed: () => onAnswer(_Answer.unsure), child: const Text('Not sure, skip  (S)')),
                        const Spacer(),
                        TextButton(onPressed: onFinish, child: const Text('Finish now  (Esc)')),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Slip(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('How we know', style: TextStyle(fontWeight: FontWeight.w700)),
                          for (final MapEntry(key: k, value: val) in v.evidence.entries) SlipRow(k, val),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Map<String, PhoneFile> files(BuildContext context) =>
      context.findAncestorStateOfType<_AccuracyPageState>()!.files;
}

/// Per group: how many were checked and how often Prune was right.
class _Results extends StatelessWidget {
  const _Results({required this.sample, required this.answers});
  final List<MapEntry<String, FileVerdict>> sample;
  final Map<String, _Answer> answers;

  @override
  Widget build(BuildContext context) {
    final rows = <JunkCategory, (int right, int wrong)>{};
    for (final e in sample) {
      final a = answers[e.key];
      if (a == null || a == _Answer.unsure) continue;
      final (r, w) = rows[e.value.verdict.category] ?? (0, 0);
      rows[e.value.verdict.category] = a == _Answer.right ? (r + 1, w) : (r, w + 1);
    }
    final right = rows.values.fold(0, (s, x) => s + x.$1), total = rows.values.fold(0, (s, x) => s + x.$1 + x.$2);
    String pct(int r, int n) => n == 0 ? '—' : '${(100 * r / n).round()}%';
    final summary = [
      'Prune accuracy check: $right of $total sure picks were right (${pct(right, total)}).',
      for (final MapEntry(key: c, value: (r, w)) in rows.entries) '${c.label}: $r of ${r + w} right (${pct(r, r + w)})',
    ].join('\n');

    return SingleChildScrollView(
      padding: const EdgeInsets.all(40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                total == 0 ? 'No answers yet' : 'Prune was right ${pct(right, total)} of the time',
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.4),
              ),
              const SizedBox(height: 8),
              Text(
                total == 0
                    ? 'Answer a few picks to see how often Prune is right.'
                    : '$right of $total sure picks you checked were ones you would remove. '
                        'Where a group scores lower, untick it in Review and check those items one by one.',
                style: const TextStyle(color: Tone.muted, height: 1.5),
              ),
              const SizedBox(height: 22),
              if (rows.isNotEmpty)
                Slip(
                  child: Column(
                    children: [
                      for (final MapEntry(key: c, value: (r, w)) in rows.entries)
                        SlipRow(c.label, '${pct(r, r + w)}   ($r of ${r + w} right)', labelWidth: 260, selectable: false),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              Row(
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: Tone.ink, side: const BorderSide(color: Tone.ink)),
                    onPressed: total == 0 ? null : () => Clipboard.setData(ClipboardData(text: summary)),
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy results'),
                  ),
                  const SizedBox(width: 12),
                  const Flexible(
                    child: Text('Only the percentages are copied: no file names or pictures.',
                        style: TextStyle(fontSize: 12, color: Tone.muted)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
