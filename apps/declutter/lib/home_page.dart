import 'dart:io';

import 'package:declutter_engine/declutter_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:phone_link/phone_link.dart';

import 'clean_dialog.dart';
import 'phone_session.dart';
import 'photo_scan.dart';
import 'review_page.dart';
import 'theme.dart';
import 'top_bar.dart';

/// First screen: find the phone, then lead with the safe pick — only what
/// Prune is sure about — and what's left for the user to check.
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.session});
  final PhoneSession session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final ready = session.state == LinkState.ready && session.info != null && session.summary != null;
          final pick = ready ? _Pick.of(session) : null;
          return Column(
            children: [
              TopBar(
                session: session,
                picked: pick?.sureBytes ?? 0,
                action: session.devices.where((d) => d.ready).length > 1 ? _PhonePicker(session: session) : null,
              ),
              Expanded(
                child: switch (session.state) {
                  LinkState.noAdb => const _Guide(
                    title: 'Phone connection tool not found',
                    steps: [
                      'Prune needs Android\'s "adb" tool to talk to your phone.',
                      'Install Android SDK Platform-Tools, then restart Prune.',
                    ],
                  ),
                  LinkState.waiting => const _Guide(
                    title: 'Plug in your Android phone',
                    steps: [
                      'On the phone: Settings → About phone → tap "Build number" 7 times.',
                      'Settings → Developer options → turn on "USB debugging".',
                      'Connect the phone to this laptop with a USB cable.',
                    ],
                    waiting: true,
                  ),
                  LinkState.unauthorized => const _Guide(
                    title: 'Allow this laptop on your phone',
                    steps: [
                      'Unlock your phone.',
                      'Tap "Allow" on the "Allow USB debugging?" message.',
                      'Tick "Always allow from this computer" to skip this next time.',
                    ],
                    waiting: true,
                  ),
                  LinkState.reading => _Guide(
                    title: 'Reading your phone…',
                    steps: [
                      if (session.readingStep.isNotEmpty) session.readingStep,
                      'Nothing on the phone is changed.',
                    ],
                    waiting: true,
                  ),
                  LinkState.forgotten => _Guide(
                  title: 'This phone is forgotten',
                  steps: const [
                    'Everything Prune saved about it on this laptop has been deleted.',
                    'Unplug it, or read it again to start fresh.',
                  ],
                  action: TextButton(onPressed: session.rescan, child: const Text('Read it again')),
                ),
                LinkState.error => _Guide(
                    title: 'Something went wrong',
                    steps: [session.error ?? 'Unknown error', 'Unplug and reconnect the phone to try again.'],
                  ),
                  LinkState.ready when pick != null => _Overview(session: session, pick: pick),
                  LinkState.ready => const _Guide(title: 'Reading your phone…', steps: [], waiting: true),
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The suggestions split the way the first screen tells them: groups
/// Prune is sure about (and how much of each it picked), and groups
/// left for the user.
class _Pick {
  _Pick(PhoneSession session) {
    final bytesOf = {for (final f in session.summary!.files) f.path: f.bytes};
    for (final cat in JunkCategory.values) {
      final items = session.suggestions.entries.where((e) => e.value.verdict.category == cat).toList();
      if (items.isEmpty) continue;
      final sure = items.where((e) => e.value.verdict.tier == Tier.sure).toList();
      final row = (
        category: cat,
        count: items.length,
        sureCount: sure.length,
        bytes: items.fold(0, (s, e) => s + (bytesOf[e.key] ?? 0)),
        sureBytes: sure.fold(0, (s, e) => s + (bytesOf[e.key] ?? 0)),
      );
      (sure.isEmpty ? check : picked).add(row);
    }
    picked.sort((a, b) => b.sureBytes.compareTo(a.sureBytes));
    check.sort((a, b) => b.bytes.compareTo(a.bytes));
  }

  /// Worked out once per set of suggestions, not on every redraw.
  static _Pick of(PhoneSession session) => _cache[session.suggestions] ??= _Pick(session);
  static final _cache = Expando<_Pick>();

  final picked = <_Row>[];
  final check = <_Row>[];
  int get sureBytes => picked.fold(0, (s, r) => s + r.sureBytes);
  int get sureCount => picked.fold(0, (s, r) => s + r.sureCount);
}

typedef _Row = ({JunkCategory category, int count, int sureCount, int bytes, int sureBytes});

class _Overview extends StatelessWidget {
  const _Overview({required this.session, required this.pick});
  final PhoneSession session;
  final _Pick pick;

  void _review(BuildContext context, [JunkCategory? at]) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          ReviewPage(session: session, initial: at, onClean: (items) => showCleanDialog(context, session, items)),
    ),
  );

  /// Development only: `PRUNE_OPEN=review` (or `review:<group>`, e.g.
  /// review:shortClip) opens Review on start, so a screen capture can check
  /// it without driving the mouse.
  static bool _devOpened = false;

  @override
  Widget build(BuildContext context) {
    final dev = Platform.environment['PRUNE_OPEN'] ?? '';
    if (kDebugMode && !_devOpened && dev.startsWith('review')) {
      _devOpened = true;
      final group = JunkCategory.values.where((c) => dev == 'review:${c.name}').firstOrNull;
      WidgetsBinding.instance.addPostFrameCallback((_) => _review(context, group));
    }
    final sum = session.summary!;
    final hidden = sum.hidden;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(40, 36, 40, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                pick.sureBytes == 0
                    ? 'Nothing Prune is sure about yet'
                    : 'You can free ${formatBytes(pick.sureBytes)}',
                style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: -0.5, height: 1.15),
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: const Text(
                  'Prune picked only what it is sure about, each with clear proof. Look through it group by '
                  'group, untick anything you want to keep, then clean. Nothing changes on the phone until you do.',
                  style: TextStyle(fontSize: 15, color: Tone.muted, height: 1.5),
                ),
              ),
              const SizedBox(height: 24),
              if (pick.picked.isNotEmpty) ...[
                Slip(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'The pick: ${formatCount(pick.sureCount)} items',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      for (final r in pick.picked)
                        _GroupLine(
                          label: r.category.label,
                          detail: r.sureCount == r.count
                              ? formatCount(r.count)
                              : '${formatCount(r.sureCount)} of ${formatCount(r.count)}',
                          bytes: r.sureBytes,
                          onTap: () => _review(context, r.category),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: () => _review(context),
                      icon: const Icon(Icons.checklist, size: 18),
                      label: const Text('Review the pick'),
                    ),
                    const SizedBox(width: 16),
                    const Text('You can untick anything before cleaning.', style: TextStyle(color: Tone.muted)),
                  ],
                ),
              ],
              if (session.photos case final p?) ...[const SizedBox(height: 22), _PhotoProgress(scan: p)],
              if (pick.check.isNotEmpty) ...[
                const SizedBox(height: 36),
                const Text('For you to check', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text(
                  'Not picked: these need your eye. Nothing here is ticked unless you tick it.',
                  style: TextStyle(color: Tone.muted),
                ),
                const SizedBox(height: 12),
                Slip(
                  child: Column(
                    children: [
                      for (final r in pick.check)
                        _GroupLine(
                          label: r.category.label,
                          detail: formatCount(r.count),
                          bytes: r.bytes,
                          onTap: () => _review(context, r.category),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 36),
              _SinceLastTime(session: session),
              const SizedBox(height: 6),
              Text(
                '${formatCount(sum.files.length)} files listed in ${(session.listTime!.inMilliseconds / 1000).toStringAsFixed(1)} s, '
                'including ${formatCount(hidden.length)} (${formatBytes(PhoneSummary.bytes(hidden))}) Android hides from its own list. '
                'Nothing on the phone was changed.',
                style: const TextStyle(fontSize: 12, color: Tone.muted),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(foregroundColor: Tone.muted, padding: EdgeInsets.zero),
                  onPressed: () => _confirmForget(context),
                  child: const Text('Forget this phone on this laptop…'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _confirmForget(BuildContext context) async {
  final session = (context.findAncestorWidgetOfExactType<HomePage>())!.session;
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Forget this phone?'),
      content: const SizedBox(
        width: 460,
        child: Text(
          'Prune will delete everything it saved about this phone on this laptop: its file list, what it '
          'measured and read from screenshots, and the history of past clean-ups (so they can no longer be '
          'undone from here).\n\nNothing on the phone changes, and backup copies in "Prune Backups" stay. '
          'Connecting the phone again starts fresh.',
          style: TextStyle(height: 1.45),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Forget this phone')),
      ],
    ),
  );
  if (yes == true) session.forgetPhone();
}

/// One group in a slip: name, count, size, and a way in.
class _GroupLine extends StatelessWidget {
  const _GroupLine({required this.label, required this.detail, required this.bytes, required this.onTap});
  final String label, detail;
  final int bytes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Tone.ruling)),
      ),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
          SizedBox(
            width: 110,
            child: Text(detail, style: Typed.factMuted, textAlign: TextAlign.right),
          ),
          SizedBox(
            width: 100,
            child: Text(formatBytes(bytes), style: Typed.fact, textAlign: TextAlign.right),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, size: 18, color: Tone.muted),
        ],
      ),
    ),
  );
}

/// The photo check: progress while it runs, then what's left (if stopped).
class _PhotoProgress extends StatelessWidget {
  const _PhotoProgress({required this.scan});
  final PhotoScan scan;

  @override
  Widget build(BuildContext context) {
    if (scan.running) {
      final left = scan.timeLeft;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Checking photos and screenshots: ${scan.done} of ${scan.total}'
                  '${left == null ? '' : ', about ${_minutes(left)} left'}',
                ),
              ),
              TextButton(onPressed: scan.stop, child: const Text('Pause')),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: scan.total == 0 ? null : scan.done / scan.total, minHeight: 3),
          const SizedBox(height: 6),
          Text(
            '${scan.step.isEmpty ? 'Working…' : scan.step} The pick grows as results come in; copies are deleted from '
            'this laptop after each batch.',
            style: const TextStyle(fontSize: 12, color: Tone.muted),
          ),
        ],
      );
    }
    final pending = scan.pending();
    return Row(
      children: [
        Icon(
          scan.error != null
              ? Icons.error_outline
              : pending == 0
              ? Icons.check_circle_outline
              : Icons.pause_circle_outline,
          size: 18,
          color: scan.error != null ? Tone.rule : Tone.muted,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            scan.error ?? (pending == 0 ? 'All photos and screenshots checked.' : '$pending photos not checked yet.'),
            style: const TextStyle(color: Tone.muted),
          ),
        ),
        if (pending > 0) TextButton(onPressed: scan.resume, child: const Text('Continue checking')),
      ],
    );
  }

  static String _minutes(Duration d) => d.inMinutes < 1 ? 'under a minute' : '${d.inMinutes} min';
}

/// "First time we've seen this phone" or "Since last time: 12 new, 3 gone".
class _SinceLastTime extends StatelessWidget {
  const _SinceLastTime({required this.session});
  final PhoneSession session;

  @override
  Widget build(BuildContext context) {
    final d = session.sinceLastTime;
    final text = d == null
        ? 'First time connecting this phone: all ${session.needAnalysis} files are new to Prune.'
        : (d.added + d.changed + d.removed == 0)
        ? 'Nothing changed since last time, so nothing needs checking again.'
        : 'Since last time: ${d.added} new, ${d.changed} edited, ${d.removed} gone. '
              'Only ${session.needAnalysis} files need checking.';
    return Row(
      children: [
        const Icon(Icons.history, size: 16, color: Tone.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 12, color: Tone.muted)),
        ),
      ],
    );
  }
}

class _PhonePicker extends StatelessWidget {
  const _PhonePicker({required this.session});
  final PhoneSession session;

  @override
  Widget build(BuildContext context) => DropdownButton<String>(
    value: session.serial,
    hint: const Text('Choose a phone'),
    underline: const SizedBox.shrink(),
    items: [
      for (final d in session.devices.where((d) => d.ready))
        DropdownMenuItem(
          value: d.serial,
          child: Text(
            PhoneCleaner.isVirtualPhone(d.serial)
                ? 'Virtual phone (${d.serial})'
                : '${d.model ?? 'Phone'} (${d.serial})',
          ),
        ),
    ],
    onChanged: (s) => s == null ? null : session.choose(s),
  );
}

class _Guide extends StatelessWidget {
  const _Guide({required this.title, required this.steps, this.waiting = false, this.action});
  final String title;
  final List<String> steps;
  final bool waiting;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Slip(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (waiting) ...[
                    const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2.2)),
                    const SizedBox(width: 14),
                  ],
                  Flexible(
                    child: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              if (steps.isNotEmpty) const SizedBox(height: 12),
              for (final (i, s) in steps.indexed)
                SlipRow('${i + 1}', s, labelWidth: 32, selectable: false, prose: true),
              if (action != null) ...[const SizedBox(height: 12), action!],
            ],
          ),
        ),
      ),
    );
  }
}
