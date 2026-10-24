import 'package:declutter_engine/declutter_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phone_link/phone_link.dart';

import 'phone_session.dart';

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

/// Big-screen review: categories on the left, items on the right.
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
  late final Map<String, PhoneFile> byPath = {for (final f in widget.session.summary!.files) f.path: f};
  late final List<JunkCategory> categories = [
    for (final c in JunkCategory.values)
      if (widget.session.suggestions.values.any((v) => v.verdict.category == c)) c,
  ];
  late JunkCategory current = categories.first;

  List<MapEntry<String, FileVerdict>> itemsIn(JunkCategory c) =>
      widget.session.suggestions.entries.where((e) => e.value.verdict.category == c).toList()
        ..sort((a, b) => byPath[b.key]!.bytes.compareTo(byPath[a.key]!.bytes));

  int bytesOf(Iterable<String> paths) => paths.fold(0, (s, p) => s + (byPath[p]?.bytes ?? 0));

  void show(JunkCategory c) => setState(() => current = c);

  @override
  Widget build(BuildContext context) {
    final items = itemsIn(current);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
            selection.setAll(items.map((e) => e.key), true),
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(title: const Text('Review suggestions')),
          body: Row(children: [
            SizedBox(width: 300, child: _CategoryList(state: this)),
            const VerticalDivider(width: 1),
            Expanded(child: _Items(state: this, items: items)),
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
  const _Items({required this.state, required this.items});
  final _ReviewPageState state;
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
                  Text(state.current.label, style: t.titleLarge),
                  Text(_explain(state.current), style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
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
        JunkCategory.shortClip => 'Camera videos under 2 seconds, usually recorded by accident.',
        JunkCategory.screenRecording => 'Screen recordings, oldest first likely safe to remove.',
        JunkCategory.largeVideo => 'Very large videos. Not ticked: check whether you still need them on the phone.',
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
    final c = Theme.of(context).colorScheme;
    return ListView.builder(
      itemCount: keys.length,
      itemBuilder: (context, i) {
        final kept = state.byPath[keys[i]];
        return Card(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Column(children: [
            if (kept != null)
              ListTile(
                leading: Icon(Icons.verified_outlined, color: c.primary),
                title: Text(kept.name),
                subtitle: Text('Keeping · ${kept.folder}'),
                trailing: Text(formatBytes(kept.bytes)),
              ),
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
    return CheckboxListTile(
      contentPadding: EdgeInsets.only(left: indent ? 40 : 20, right: 20),
      controlAffinity: ListTileControlAffinity.leading,
      value: state.selection.has(entry.key),
      onChanged: (_) => state.selection.toggle(entry.key),
      secondary: SizedBox(
        width: 150,
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(formatBytes(f.bytes), style: t.titleSmall),
          Text('${date.day}/${date.month}/${date.year}', style: t.bodySmall?.copyWith(color: c.onSurfaceVariant)),
        ]),
      ),
      title: Row(children: [
        Icon(_icon(f), size: 18, color: c.onSurfaceVariant),
        const SizedBox(width: 8),
        Flexible(child: Text(f.name, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 8),
        if (v.tier == Tier.sure)
          Text('sure', style: t.labelSmall?.copyWith(color: c.primary, fontWeight: FontWeight.w700)),
      ]),
      subtitle: Text('${f.folder}\n${v.reasons.join(' · ')}', maxLines: 2, overflow: TextOverflow.ellipsis),
      isThreeLine: true,
    );
  }

  static IconData _icon(PhoneFile f) => f.isVideo
      ? Icons.movie_outlined
      : f.isImage
          ? Icons.photo_outlined
          : f.isAudio
              ? Icons.graphic_eq
              : Icons.description_outlined;
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
                    : () => state.widget.onClean!([for (final p in picked) state.byPath[p]!]),
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
