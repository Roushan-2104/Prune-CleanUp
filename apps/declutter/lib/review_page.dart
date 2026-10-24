import 'package:declutter_engine/declutter_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phone_link/phone_link.dart';

import 'media_view.dart';
import 'phone_session.dart';
import 'review_media.dart';

/// The user's ticks while reviewing. "Sure" suggestions start ticked.
class Selection extends ChangeNotifier {
  Selection(Map<String, FileVerdict> suggestions)
      : picked = {for (final e in suggestions.entries) if (e.value.verdict.tier == Tier.sure) e.key};

  final Set<String> picked;

  bool has(String path) => picked.contains(path);

  void toggle(String path) {
    picked.contains(path) ? picked.remove(path) : picked.add(path);
    notifyListeners();
  }

  void setAll(Iterable<String> paths, bool on) {
    on ? picked.addAll(paths) : picked.removeAll(paths);
    notifyListeners();
  }
}

/// Big-screen review: categories on the left, items in the middle, and the
/// selected item on the right — shown large, next to the copy it matched,
/// with the evidence ("How we know").
class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key, required this.session, this.onClean});
  final PhoneSession session;

  /// Called with the ticked items when the user presses Clean.
  final void Function(List<PhoneFile> items)? onClean;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  late final Selection selection = Selection(widget.session.suggestions);
  late final ReviewMedia? media =
      widget.session.serial == null ? null : ReviewMedia(widget.session.adb, widget.session.serial!);
  JunkCategory? _current;

  /// The item shown in the detail panel.
  String? focused;

  // The phone is re-read after every clean-up or undo, so everything below
  // is derived from the session's *current* data on each build.
  PhoneSummary? _summarySeen;
  Map<String, PhoneFile> _byPath = {};

  Map<String, PhoneFile> get byPath {
    final s = widget.session.summary;
    if (!identical(s, _summarySeen)) {
      _summarySeen = s;
      _byPath = {for (final f in s?.files ?? const <PhoneFile>[]) f.path: f};
      // Forget ticks on files that are no longer on the phone.
      selection.picked.removeWhere((p) => !_byPath.containsKey(p));
    }
    return _byPath;
  }

  /// Suggestions whose file is in the current listing.
  Iterable<MapEntry<String, FileVerdict>> get _live =>
      widget.session.suggestions.entries.where((e) => byPath.containsKey(e.key));

  List<JunkCategory> get categories => [
        for (final c in JunkCategory.values)
          if (_live.any((e) => e.value.verdict.category == c)) c,
      ];

  JunkCategory? get current {
    final cats = categories;
    if (_current == null || !cats.contains(_current)) _current = cats.firstOrNull;
    return _current;
  }

  List<MapEntry<String, FileVerdict>> itemsIn(JunkCategory? c) =>
      _live.where((e) => e.value.verdict.category == c).toList()
        ..sort((a, b) => byPath[b.key]!.bytes.compareTo(byPath[a.key]!.bytes));

  int bytesOf(Iterable<String> paths) => paths.fold(0, (s, p) => s + (byPath[p]?.bytes ?? 0));

  void show(JunkCategory c) => setState(() {
        _current = c;
        focused = null;
      });

  void focus(String path) => setState(() => focused = path);

  void _move(List<MapEntry<String, FileVerdict>> items, int step) {
    if (items.isEmpty) return;
    final i = items.indexWhere((e) => e.key == focused);
    focus(items[(i < 0 ? 0 : i + step).clamp(0, items.length - 1)].key);
  }

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    media?.dispose();
    super.dispose();
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (widget.session.state != LinkState.ready) {
      return Scaffold(
        appBar: AppBar(title: const Text('Review suggestions')),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(widget.session.readingStep.isEmpty ? 'Reading the phone again…' : widget.session.readingStep),
          ]),
        ),
      );
    }
    final current = this.current;
    if (current == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Review suggestions')),
        body: const Center(child: Text('Nothing left to suggest on this phone.')),
      );
    }
    final items = itemsIn(current);
    final focusedEntry = items.where((e) => e.key == focused).firstOrNull;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
            selection.setAll(items.map((e) => e.key), true),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(items, 1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(items, -1),
        const SingleActivator(LogicalKeyboardKey.space): () {
          if (focusedEntry != null) selection.toggle(focusedEntry.key);
        },
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(title: const Text('Review suggestions')),
          body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(width: 260, child: _CategoryList(state: this)),
            const VerticalDivider(width: 1),
            Expanded(child: _Items(state: this, category: current, items: items)),
            const VerticalDivider(width: 1),
            SizedBox(
              width: 480,
              child: focusedEntry == null
                  ? const _DetailHint()
                  : _Detail(key: ValueKey(focusedEntry.key), state: this, entry: focusedEntry),
            ),
          ]),
          bottomNavigationBar: _CleanBar(state: this),
        ),
      ),
    );
  }
}

class _CategoryList extends StatelessWidget {
  const _CategoryList({required this.state});
  final _ReviewPageState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: state.selection,
      builder: (context, _) => ListView(padding: const EdgeInsets.all(8), children: [
        for (final c in state.categories)
          Builder(builder: (context) {
            final items = state.itemsIn(c);
            final sure = items.where((e) => e.value.verdict.tier == Tier.sure).map((e) => e.key);
            final picked = items.where((e) => state.selection.has(e.key)).map((e) => e.key);
            return ListTile(
              selected: c == state.current,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              title: Text(c.label),
              subtitle: Text('${items.length} items · ${formatBytes(state.bytesOf(items.map((e) => e.key)))}'
                  '${sure.isNotEmpty ? ' · ${formatBytes(state.bytesOf(sure))} sure' : ''}'),
              trailing: picked.isEmpty ? null : Text('${picked.length} ✓', style: t.labelLarge),
              onTap: () => state.show(c),
            );
          }),
      ]),
    );
  }
}

class _Items extends StatelessWidget {
  const _Items({required this.state, required this.category, required this.items});
  final _ReviewPageState state;
  final JunkCategory category;
  final List<MapEntry<String, FileVerdict>> items;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme, c = Theme.of(context).colorScheme;
    final paths = items.map((e) => e.key).toList();
    final isDuplicates = items.any((e) => e.value.matchPath != null);

    return ListenableBuilder(
      listenable: state.selection,
      builder: (context, _) {
        final allPicked = paths.every(state.selection.has);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(category.label, style: t.titleLarge),
                  Text(_explain(category), style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
                  Text('Click an item to see it large · ↑ ↓ to move · Space to tick',
                      style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                ]),
              ),
              TextButton(
                onPressed: () => state.selection.setAll(paths, !allPicked),
                child: Text(allPicked ? 'Untick all' : 'Tick all (Ctrl+A)'),
              ),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: isDuplicates
                ? _DuplicateGroups(state: state, items: items)
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, i) => _Row(state: state, entry: items[i]),
                  ),
          ),
        ]);
      },
    );
  }

  static String _explain(JunkCategory c) => switch (c) {
        JunkCategory.whatsappSent => 'Copies WhatsApp keeps of things you sent. Chats will show them as no longer on this phone.',
        JunkCategory.exactDuplicate => 'Byte-for-byte identical copies, confirmed by fingerprint. The original (green) stays.',
        JunkCategory.shortClip => 'Camera videos under 2 seconds, usually recorded by accident. Play them to check.',
        JunkCategory.screenRecording => 'Screen recordings, oldest first likely safe to remove.',
        JunkCategory.largeVideo => 'Very large videos. Not ticked: check whether you still need them on the phone.',
        JunkCategory.oldInstaller => 'App installer files. Installed apps keep working without them.',
        JunkCategory.oldVoiceNote => 'WhatsApp voice notes older than 3 months. Not ticked: some may matter to you.',
        JunkCategory.oldDocument => 'Downloads and WhatsApp documents untouched for 6+ months. Not ticked: check first.',
        JunkCategory.cacheFiles => 'Gallery previews and WhatsApp statuses you viewed. Rebuilt or expired automatically.',
        _ => 'Ticked items are ones Declutter is sure about. Others are for you to check.',
      };
}

/// Duplicates: the kept original (green) with its copies beneath it.
class _DuplicateGroups extends StatelessWidget {
  const _DuplicateGroups({required this.state, required this.items});
  final _ReviewPageState state;
  final List<MapEntry<String, FileVerdict>> items;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<MapEntry<String, FileVerdict>>>{};
    for (final e in items) {
      groups.putIfAbsent(e.value.matchPath ?? e.key, () => []).add(e);
    }
    final keys = groups.keys.toList();
    final t = Theme.of(context).textTheme, c = Theme.of(context).colorScheme;
    return ListView.builder(
      itemCount: keys.length,
      itemBuilder: (context, i) {
        final kept = state.byPath[keys[i]];
        return Card(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            if (kept != null)
              ListTile(
                contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                leading: Container(
                  decoration: BoxDecoration(border: Border.all(color: Colors.green, width: 2), borderRadius: BorderRadius.circular(10)),
                  child: FileThumb(file: kept, media: state.media),
                ),
                title: Text(kept.name, overflow: TextOverflow.ellipsis),
                subtitle: Text('Keeping · ${kept.folder}'),
                trailing: Text('KEEP', style: t.labelMedium?.copyWith(color: Colors.green, fontWeight: FontWeight.w700)),
              ),
            Divider(height: 1, color: c.outlineVariant),
            for (final e in groups[keys[i]]!) _Row(state: state, entry: e, indent: true),
          ]),
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.state, required this.entry, this.indent = false});
  final _ReviewPageState state;
  final MapEntry<String, FileVerdict> entry;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    final f = state.byPath[entry.key]!;
    final v = entry.value.verdict;
    final t = Theme.of(context).textTheme, c = Theme.of(context).colorScheme;
    final date = DateTime.fromMillisecondsSinceEpoch(f.modifiedSec * 1000);
    return ListTile(
      selected: state.focused == entry.key,
      selectedTileColor: c.secondaryContainer.withValues(alpha: 0.5),
      contentPadding: EdgeInsets.only(left: indent ? 28 : 12, right: 20, top: 2, bottom: 2),
      onTap: () => state.focus(entry.key),
      leading: Row(mainAxisSize: MainAxisSize.min, children: [
        Checkbox(value: state.selection.has(entry.key), onChanged: (_) => state.selection.toggle(entry.key)),
        FileThumb(file: f, media: state.media),
      ]),
      title: Row(children: [
        Flexible(child: Text(f.name, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 8),
        if (v.tier == Tier.sure)
          Text('sure', style: t.labelSmall?.copyWith(color: c.primary, fontWeight: FontWeight.w700)),
      ]),
      subtitle: Text('${f.folder}\n${v.reasons.join(' · ')}', maxLines: 2, overflow: TextOverflow.ellipsis),
      isThreeLine: true,
      trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(formatBytes(f.bytes), style: t.titleSmall),
        Text('${date.day}/${date.month}/${date.year}', style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
      ]),
    );
  }
}

class _DetailHint extends StatelessWidget {
  const _DetailHint();
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.visibility_outlined, size: 40, color: c.onSurfaceVariant),
          const SizedBox(height: 12),
          Text('Click an item to see it here — large, next to the copy it matched, '
              'with exactly why Declutter picked it.',
              textAlign: TextAlign.center, style: TextStyle(color: c.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

/// The selected item, large: side by side with its match, plus the evidence.
class _Detail extends StatelessWidget {
  const _Detail({super.key, required this.state, required this.entry});
  final _ReviewPageState state;
  final MapEntry<String, FileVerdict> entry;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme, c = Theme.of(context).colorScheme;
    final f = state.byPath[entry.key]!;
    final v = entry.value.verdict;
    final match = entry.value.matchPath == null ? null : state.byPath[entry.value.matchPath];

    Widget labelled(String label, Color color, PhoneFile file) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: t.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(border: Border.all(color: color, width: 3), borderRadius: BorderRadius.circular(12)),
              child: MediaView(file: file, media: state.media, height: 240),
            ),
            const SizedBox(height: 6),
            Text(file.name, style: t.bodySmall, overflow: TextOverflow.ellipsis),
            Text(file.folder, style: t.bodySmall?.copyWith(color: c.onSurfaceVariant), overflow: TextOverflow.ellipsis),
          ]),
        );

    return ListenableBuilder(
      listenable: state.selection,
      builder: (context, _) => ListView(padding: const EdgeInsets.all(20), children: [
        if (match != null)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            labelled('Keeping', Colors.green, match),
            const SizedBox(width: 12),
            labelled(state.selection.has(entry.key) ? 'Removing this copy' : 'This copy (not ticked)', c.error, f),
          ])
        else ...[
          MediaView(key: GlobalObjectKey<MediaViewState>(f.path), file: f, media: state.media, height: 340),
          if (f.isVideo && state.media != null) ...[
            const SizedBox(height: 8),
            Filmstrip(
              file: f,
              media: state.media!,
              onTapFrame: (p) => GlobalObjectKey<MediaViewState>(f.path).currentState?.play(from: p),
            ),
          ],
          const SizedBox(height: 10),
          Text(f.name, style: t.titleMedium),
          Text(f.folder, style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
        ],
        const SizedBox(height: 14),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: state.selection.has(entry.key),
          onChanged: (_) => state.selection.toggle(entry.key),
          title: Text('Remove ${f.name}'),
          subtitle: Text('${formatBytes(f.bytes)} · ${v.tier == Tier.sure ? 'Declutter is sure' : 'For you to check'}'),
        ),
        const Divider(),
        Text('Why it was picked', style: t.titleSmall),
        const SizedBox(height: 4),
        for (final r in v.reasons)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.chevron_right, size: 18, color: c.onSurfaceVariant),
              const SizedBox(width: 4),
              Expanded(child: Text(r)),
            ]),
          ),
        if (v.evidence.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: c.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.fact_check_outlined, size: 18, color: c.primary),
                const SizedBox(width: 8),
                Text('How we know', style: t.titleSmall),
              ]),
              const SizedBox(height: 8),
              for (final MapEntry(key: k, value: val) in v.evidence.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 150, child: Text(k, style: t.bodySmall?.copyWith(color: c.onSurfaceVariant))),
                    Expanded(child: SelectableText(val, style: t.bodyMedium)),
                  ]),
                ),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _CleanBar extends StatelessWidget {
  const _CleanBar({required this.state});
  final _ReviewPageState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: state.selection,
      builder: (context, _) {
        final picked = state.selection.picked;
        return Material(
          elevation: 3,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(children: [
              Expanded(
                child: Text(
                  picked.isEmpty ? 'Nothing ticked yet' : 'Selected: ${picked.length} items · ${formatBytes(state.bytesOf(picked))}',
                  style: t.titleMedium,
                ),
              ),
              FilledButton.icon(
                onPressed: picked.isEmpty || state.widget.onClean == null
                    ? null
                    : () => state.widget.onClean!([
                          for (final p in picked)
                            ?state.byPath[p],
                        ]),
                icon: const Icon(Icons.cleaning_services_outlined),
                label: const Text('Clean…'),
              ),
            ]),
          ),
        );
      },
    );
  }
}
