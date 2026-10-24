import 'package:declutter_engine/declutter_engine.dart';
import 'package:flutter/material.dart';
import 'package:phone_link/phone_link.dart';

import 'clean_dialog.dart';
import 'phone_session.dart';
import 'review_page.dart';

/// First screen: find the phone, then show what's on it. Read-only.
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.session});
  final PhoneSession session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: session,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.all(28),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('Declutter', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(width: 12),
                const _ReadOnlyBadge(),
                const Spacer(),
                if (session.devices.where((d) => d.ready).length > 1)
                  DropdownButton<String>(
                    value: session.serial,
                    hint: const Text('Choose a phone'),
                    items: [
                      for (final d in session.devices.where((d) => d.ready))
                        DropdownMenuItem(
                          value: d.serial,
                          child: Text(PhoneCleaner.isVirtualPhone(d.serial)
                              ? 'Virtual phone (${d.serial})'
                              : '${d.model ?? 'Phone'} (${d.serial})'),
                        ),
                    ],
                    onChanged: (s) => s == null ? null : session.choose(s),
                  ),
              ]),
              const SizedBox(height: 24),
              Expanded(
                child: switch (session.state) {
                  LinkState.noAdb => const _Guide(
                      title: 'Phone connection tool not found',
                      steps: ['Declutter needs Android\'s "adb" tool to talk to your phone.',
                        'Install Android SDK Platform-Tools, then restart Declutter.']),
                  LinkState.waiting => const _Guide(
                      title: 'Plug in your Android phone',
                      steps: [
                        'On the phone: Settings → About phone → tap "Build number" 7 times.',
                        'Settings → Developer options → turn on "USB debugging".',
                        'Connect the phone to this laptop with a USB cable.',
                      ],
                      waiting: true),
                  LinkState.unauthorized => const _Guide(
                      title: 'Allow this laptop on your phone',
                      steps: ['Unlock your phone.', 'Tap "Allow" on the "Allow USB debugging?" message.',
                        'Tick "Always allow from this computer" to skip this next time.'],
                      waiting: true),
                  LinkState.reading => _Guide(
                      title: 'Reading your phone…',
                      steps: [if (session.readingStep.isNotEmpty) session.readingStep, 'Nothing on the phone is changed.'],
                      waiting: true),
                  LinkState.error => _Guide(title: 'Something went wrong', steps: [session.error ?? 'Unknown error', 'Unplug and reconnect the phone to try again.']),
                  LinkState.ready => _Overview(session: session),
                },
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// "Found so far" — suggestions from file facts and on-phone fingerprints.
class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.session});
  final PhoneSession session;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme, c = Theme.of(context).colorScheme;
    final bytesOf = {for (final f in session.summary!.files) f.path: f.bytes};
    final rows = <(JunkCategory, int, int, int)>[]; // category, files, sure bytes, to-check bytes
    for (final cat in JunkCategory.values) {
      final items = session.suggestions.entries.where((e) => e.value.verdict.category == cat);
      if (items.isEmpty) continue;
      var sure = 0, check = 0;
      for (final e in items) {
        e.value.verdict.tier == Tier.sure ? sure += bytesOf[e.key]! : check += bytesOf[e.key]!;
      }
      rows.add((cat, items.length, sure, check));
    }
    final total = rows.fold(0, (s, r) => s + r.$3 + r.$4);
    final hidden = session.summary!.hidden;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Found so far', style: t.titleMedium),
          const SizedBox(height: 4),
          Text(formatBytes(total), style: t.displaySmall?.copyWith(fontWeight: FontWeight.w700, color: c.primary)),
          Text('${hidden.length} files (${formatBytes(PhoneSummary.bytes(hidden))}) are hidden from Android\'s own file '
              'list. Declutter checked them too.', style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
          const SizedBox(height: 12),
          for (final (cat, n, sure, check) in rows)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(cat.label),
              subtitle: Text('$n files'),
              trailing: Wrap(spacing: 8, children: [
                if (sure > 0) Chip(label: Text('Sure · ${formatBytes(sure)}'), visualDensity: VisualDensity.compact),
                if (check > 0) Chip(label: Text('To check · ${formatBytes(check)}'), visualDensity: VisualDensity.compact),
              ]),
            ),
          const SizedBox(height: 4),
          Text('Photos and screenshots are checked after copying them to this laptop (next step).',
              style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
          const SizedBox(height: 12),
          if (rows.isNotEmpty)
            FilledButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ReviewPage(
                  session: session,
                  onClean: (items) => showCleanDialog(context, session, items),
                ),
              )),
              icon: const Icon(Icons.checklist),
              label: const Text('Review suggestions'),
            ),
        ]),
      ),
    );
  }
}

/// "First time we've seen this phone" or "Since last time: 12 new, 3 gone".
class _SinceLastTime extends StatelessWidget {
  const _SinceLastTime({required this.session});
  final PhoneSession session;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final d = session.sinceLastTime;
    final text = d == null
        ? 'First time connecting this phone. All ${session.needAnalysis} files are new to Declutter.'
        : (d.added + d.changed + d.removed == 0)
            ? 'Nothing changed since last time — no need to check anything again.'
            : 'Since last time: ${d.added} new, ${d.changed} edited, ${d.removed} gone. '
                'Only ${session.needAnalysis} files need checking.';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: c.primaryContainer, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(Icons.history, color: c.onPrimaryContainer),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: TextStyle(color: c.onPrimaryContainer))),
      ]),
    );
  }
}

class _ReadOnlyBadge extends StatelessWidget {
  const _ReadOnlyBadge();
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Declutter only reads your phone. Nothing is changed until you approve a clean-up.',
      child: Chip(
        avatar: Icon(Icons.lock_outline, size: 16, color: c.primary),
        label: const Text('Read-only'),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _Guide extends StatelessWidget {
  const _Guide({required this.title, required this.steps, this.waiting = false});
  final String title;
  final List<String> steps;
  final bool waiting;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (waiting) ...[const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.5)), const SizedBox(width: 14)],
            Flexible(child: Text(title, style: t.titleLarge)),
          ]),
          const SizedBox(height: 16),
          for (final (i, s) in steps.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CircleAvatar(radius: 12, child: Text('${i + 1}', style: t.labelMedium)),
                const SizedBox(width: 12),
                Expanded(child: Text(s, style: t.bodyLarge)),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.session});
  final PhoneSession session;

  @override
  Widget build(BuildContext context) {
    final info = session.info!, sum = session.summary!;
    final t = Theme.of(context).textTheme, c = Theme.of(context).colorScheme;
    final usedShare = info.totalBytes == 0 ? 0.0 : info.usedBytes / info.totalBytes;

    Widget stat(String label, Iterable files, int bytes, IconData icon) => Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(icon, color: c.primary),
                const SizedBox(height: 8),
                Text(formatBytes(bytes), style: t.titleLarge),
                Text('${files.length} $label', style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
              ]),
            ),
          ),
        );

    return ListView(children: [
      Text('${info.brand} ${info.model} · Android ${info.androidVersion}', style: t.titleLarge),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(value: usedShare, minHeight: 14),
      ),
      const SizedBox(height: 6),
      Text('${formatBytes(info.usedBytes)} used of ${formatBytes(info.totalBytes)} · ${formatBytes(info.freeBytes)} free',
          style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
      const SizedBox(height: 16),
      _SinceLastTime(session: session),
      const SizedBox(height: 16),
      _Suggestions(session: session),
      const SizedBox(height: 16),
      Row(children: [
        stat('photos', sum.photos, PhoneSummary.bytes(sum.photos), Icons.photo_outlined),
        stat('videos', sum.videos, PhoneSummary.bytes(sum.videos), Icons.movie_outlined),
        stat('audio files', sum.audio, PhoneSummary.bytes(sum.audio), Icons.graphic_eq),
        stat('documents & other', sum.other, PhoneSummary.bytes(sum.other), Icons.description_outlined),
      ]),
      const SizedBox(height: 22),
      Text('Biggest folders', style: t.titleMedium),
      const SizedBox(height: 8),
      Card(
        child: Column(children: [
          for (final e in sum.topFolders())
            ListTile(
              dense: true,
              leading: const Icon(Icons.folder_outlined),
              title: Text(e.key.isEmpty ? '(phone storage root)' : e.key),
              trailing: Text(formatBytes(e.value), style: t.bodyMedium),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      Text('Listed ${sum.files.length} files in ${(session.listTime!.inMilliseconds / 1000).toStringAsFixed(1)} s. '
          'Nothing on the phone was changed.',
          style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
    ]);
  }
}
