import 'dart:io';
import 'dart:math' as math;

import 'package:declutter_engine/declutter_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phone_link/phone_link.dart';

import 'media_view.dart';
import 'phone_session.dart';
import 'review_media.dart';
import 'theme.dart';
import 'top_bar.dart';

/// The user's ticks while reviewing. "Sure" suggestions start ticked.
class Selection extends ChangeNotifier {
  Selection(Map<String, FileVerdict> suggestions)
    : picked = {
        for (final e in suggestions.entries)
          if (e.value.verdict.tier == Tier.sure) e.key,
      };

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

/// Big-screen review: groups on the left, the open group as cards (picture,
/// one typed reason) in the middle, and the focused item on the right —
/// large, next to the copy it matched, with its "How we know" slip.
class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key, required this.session, this.onClean, this.initial});
  final PhoneSession session;

  /// The group to open first (else the biggest sure one).
  final JunkCategory? initial;

  /// Called with the ticked items when the user presses Clean.
  final void Function(List<PhoneFile> items)? onClean;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

typedef _Entry = MapEntry<String, FileVerdict>;

class _ReviewPageState extends State<ReviewPage> {
  late final Selection selection = Selection(widget.session.suggestions);
  late final ReviewMedia? media = widget.session.serial == null
      ? null
      : ReviewMedia(widget.session.adb, widget.session.serial!);
  late JunkCategory? _current = widget.initial;

  /// The item shown in the detail panel.
  String? focused;

  /// Cards per row in the grid, for ↑ ↓.
  int columns = 4;

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
  Iterable<_Entry> get _live => widget.session.suggestions.entries.where((e) => byPath.containsKey(e.key));

  /// Groups in the order Home lists them: sure ones by the space their sure
  /// items free, then the rest by size.
  List<JunkCategory> get categories {
    final sure = <JunkCategory, int>{}, all = <JunkCategory, int>{};
    for (final e in _live) {
      final c = e.value.verdict.category, b = byPath[e.key]!.bytes;
      all.update(c, (v) => v + b, ifAbsent: () => b);
      if (e.value.verdict.tier == Tier.sure) sure.update(c, (v) => v + b, ifAbsent: () => b);
    }
    return all.keys.toList()..sort((a, b) {
      final sa = sure[a], sb = sure[b];
      if ((sa == null) != (sb == null)) return sa == null ? 1 : -1;
      return sa != null ? sb!.compareTo(sa) : all[b]!.compareTo(all[a]!);
    });
  }

  /// A group belongs under "Sure to remove" when Declutter is sure of some of it.
  bool isSureGroup(JunkCategory c) => itemsIn(c).any((e) => e.value.verdict.tier == Tier.sure);

  JunkCategory? get current {
    final cats = categories;
    if (_current == null || !cats.contains(_current)) {
      _current = cats.where(isSureGroup).firstOrNull ?? cats.firstOrNull;
    }
    return _current;
  }

  /// Biggest first, kept together by app ("WhatsApp chats", "PhonePe
  /// payments"…) with the biggest group on top, as the list shows them.
  List<_Entry> itemsIn(JunkCategory? c) {
    final items = _live.where((e) => e.value.verdict.category == c).toList();
    final groupBytes = <String?, int>{};
    for (final e in items) {
      groupBytes.update(_groupOf(e), (b) => b + byPath[e.key]!.bytes, ifAbsent: () => byPath[e.key]!.bytes);
    }
    return items..sort((a, b) {
      final ga = _groupOf(a), gb = _groupOf(b);
      if (ga != gb) {
        // Named groups first; catch-alls ("Other WhatsApp chats") last.
        final oa = ga == null || ga.startsWith('Other '), ob = gb == null || gb.startsWith('Other ');
        if (oa != ob) return oa ? 1 : -1;
        final byBytes = groupBytes[gb]!.compareTo(groupBytes[ga]!);
        return byBytes != 0 ? byBytes : ga!.compareTo(gb!);
      }
      return byPath[b.key]!.bytes.compareTo(byPath[a.key]!.bytes);
    });
  }

  /// The sub-group a card sits in: the kept original for copies, else the
  /// verdict's label ("Nikhil · WhatsApp").
  static String? _groupOf(_Entry e) => e.value.matchPath != null ? 'keep:${e.value.matchPath}' : e.value.verdict.label;

  int bytesOf(Iterable<String> paths) => paths.fold(0, (s, p) => s + (byPath[p]?.bytes ?? 0));

  void show(JunkCategory c) => setState(() {
    _current = c;
    focused = null;
  });

  void focus(String path) => setState(() => focused = path);

  void _move(List<_Entry> items, int step) {
    if (items.isEmpty) return;
    final i = items.indexWhere((e) => e.key == focused);
    focus(items[(i < 0 ? 0 : i + step).clamp(0, items.length - 1)].key);
  }

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
    // Development only (see HomePage): show the first card's detail too.
    if (kDebugMode && Platform.environment['DECLUTTER_OPEN'] == 'review') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final first = itemsIn(current).firstOrNull;
        if (first != null) focus(first.key);
      });
    }
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

  void _clean() => widget.onClean?.call([for (final p in selection.picked) ?byPath[p]]);

  @override
  Widget build(BuildContext context) {
    final back = IconButton(
      tooltip: 'Back (Esc)',
      icon: const Icon(Icons.arrow_back, color: Tone.ink),
      onPressed: () => Navigator.of(context).maybePop(),
    );
    final top = ListenableBuilder(
      listenable: selection,
      builder: (context, _) {
        final bytes = bytesOf(selection.picked);
        return TopBar(
          session: widget.session,
          picked: bytes,
          leading: back,
          action: FilledButton.icon(
            onPressed: selection.picked.isEmpty || widget.onClean == null ? null : _clean,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(selection.picked.isEmpty ? 'Nothing picked' : 'Clean ${formatBytes(bytes)}…'),
          ),
        );
      },
    );

    if (widget.session.state != LinkState.ready) {
      return Scaffold(
        body: Column(
          children: [
            top,
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                    const SizedBox(height: 16),
                    Text(
                      widget.session.readingStep.isEmpty ? 'Reading the phone again…' : widget.session.readingStep,
                      style: const TextStyle(color: Tone.muted),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    final current = this.current;
    if (current == null) {
      return Scaffold(
        body: Column(
          children: [
            top,
            const Expanded(
              child: Center(
                child: Text('Nothing left to suggest on this phone.', style: TextStyle(color: Tone.muted)),
              ),
            ),
          ],
        ),
      );
    }
    final items = itemsIn(current);
    final focusedEntry = items.where((e) => e.key == focused).firstOrNull;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
            selection.setAll(items.map((e) => e.key), true),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _move(items, 1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _move(items, -1),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(items, columns),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(items, -columns),
        const SingleActivator(LogicalKeyboardKey.space): () {
          if (focusedEntry != null) selection.toggle(focusedEntry.key);
        },
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              top,
              Expanded(
                // Side panels scale with the window so the cards keep at
                // least two or three columns on a 1280-wide laptop screen.
                child: LayoutBuilder(
                  builder: (context, box) {
                    final w = box.maxWidth;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: (w * 0.19).clamp(230.0, 290.0),
                          child: _Rail(state: this),
                        ),
                        Expanded(
                          child: _Group(state: this, category: current, items: items),
                        ),
                        Container(
                          width: (w * 0.28).clamp(340.0, 440.0),
                          decoration: const BoxDecoration(
                            color: Tone.paper,
                            border: Border(left: BorderSide(color: Tone.line)),
                          ),
                          child: focusedEntry == null
                              ? const _DetailHint()
                              : _Detail(key: ValueKey(focusedEntry.key), state: this, entry: focusedEntry),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The groups, split into what Declutter is sure about and what's for the
/// user to check. Each carries a bar sized by the space it holds.
class _Rail extends StatelessWidget {
  const _Rail({required this.state});
  final _ReviewPageState state;

  @override
  Widget build(BuildContext context) {
    final cats = state.categories;
    final sure = cats.where(state.isSureGroup).toList();
    final check = cats.where((c) => !state.isSureGroup(c)).toList();
    final sizes = {for (final c in cats) c: state.bytesOf(state.itemsIn(c).map((e) => e.key))};
    final biggest = sizes.values.fold(1, math.max);

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 6),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Tone.muted),
      ),
    );

    return Container(
      decoration: const BoxDecoration(
        color: Tone.paper,
        border: Border(right: BorderSide(color: Tone.line)),
      ),
      child: ListenableBuilder(
        listenable: state.selection,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
          children: [
            if (sure.isNotEmpty) heading('Sure to remove'),
            for (final c in sure) _RailEntry(state: state, category: c, bytes: sizes[c]!, biggest: biggest),
            if (check.isNotEmpty) heading('For you to check'),
            for (final c in check) _RailEntry(state: state, category: c, bytes: sizes[c]!, biggest: biggest),
          ],
        ),
      ),
    );
  }
}

class _RailEntry extends StatelessWidget {
  const _RailEntry({required this.state, required this.category, required this.bytes, required this.biggest});
  final _ReviewPageState state;
  final JunkCategory category;
  final int bytes, biggest;

  @override
  Widget build(BuildContext context) {
    final on = category == state.current;
    final items = state.itemsIn(category);
    final picked = items.where((e) => state.selection.has(e.key)).length;
    // Square root, so a 23 GB group doesn't flatten the 11 MB ones to nothing.
    final share = math.sqrt(bytes / biggest);
    return Material(
      color: on ? Tone.blank : Colors.transparent,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => state.show(category),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      category.label,
                      style: TextStyle(fontWeight: on ? FontWeight.w600 : FontWeight.w400, color: Tone.ink),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(formatBytes(bytes), style: Typed.factMuted),
                ],
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      // Ink, not red: red reads as a warning in a deletion app.
                      // Groups under 5% of the biggest get no bar (it would be a stray dot).
                      child: share < 0.05
                          ? const SizedBox(height: 3)
                          : FractionallySizedBox(
                              widthFactor: share,
                              child: Container(height: 3, color: on ? Tone.ink : Tone.muted.withValues(alpha: 0.45)),
                            ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    picked == 0
                        ? formatCount(items.length)
                        : '${formatCount(picked)} of ${formatCount(items.length)} picked',
                    style: Typed.factMuted,
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

/// The open group: a short header, then cards in sub-groups (a person, an
/// app, or the original a set of copies matches), each with its own tick-all.
class _Group extends StatelessWidget {
  const _Group({required this.state, required this.category, required this.items});
  final _ReviewPageState state;
  final JunkCategory category;
  final List<_Entry> items;

  static const cardWidth = 230.0, gap = 16.0, pad = 28.0;

  @override
  Widget build(BuildContext context) {
    final paths = items.map((e) => e.key).toList();
    final groups = <String?, List<_Entry>>{};
    for (final e in items) {
      groups.putIfAbsent(_ReviewPageState._groupOf(e), () => []).add(e);
    }
    final split = groups.length > 1 || groups.keys.single != null;

    return ListenableBuilder(
      listenable: state.selection,
      builder: (context, _) {
        final picked = paths.where(state.selection.has).length;
        final allPicked = picked == paths.length;
        return LayoutBuilder(
          builder: (context, box) {
            state.columns = math.max(1, ((box.maxWidth - 2 * pad + gap) / (cardWidth + gap)).floor());
            // Windows already draws a scrollbar on every scrolling view.
            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(pad, 24, pad, 8),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                category.label,
                                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.3),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${formatCount(paths.length)} items · ${formatBytes(state.bytesOf(paths))} · ${formatCount(picked)} picked',
                                style: Typed.factMuted,
                              ),
                              const SizedBox(height: 8),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 680),
                                child: Text(
                                  _explain(category),
                                  style: const TextStyle(color: Tone.muted, height: 1.45),
                                ),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () => state.selection.setAll(paths, !allPicked),
                          child: Text(allPicked ? 'Untick all' : 'Tick all  (Ctrl+A)'),
                        ),
                      ],
                    ),
                  ),
                ),
                for (final MapEntry(key: g, value: members) in groups.entries) ...[
                  if (split)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(pad, 18, pad, 12),
                      sliver: SliverToBoxAdapter(
                        child: _GroupHeader(state: state, group: g, members: members),
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(pad, split ? 0 : 16, pad, 8),
                    sliver: SliverGrid(
                      // The same column count ↑ ↓ use, so they move straight up and down.
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: state.columns,
                        mainAxisSpacing: gap,
                        crossAxisSpacing: gap,
                        mainAxisExtent: 268,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => _Card(state: state, entry: members[i]),
                        childCount: members.length,
                      ),
                    ),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            );
          },
        );
      },
    );
  }

  static String _explain(JunkCategory c) => switch (c) {
    JunkCategory.whatsappSent =>
      'Copies WhatsApp keeps of things you sent. Chats will show them as no longer on this phone.',
    JunkCategory.exactDuplicate => 'Byte-for-byte copies, confirmed by fingerprint. The original in each set stays.',
    JunkCategory.nearDuplicate =>
      'Photos that look the same. The sharpest in each set stays; the others are its copies.',
    JunkCategory.chatScreenshot => 'Screenshots of chats, grouped by who the chat is with.',
    JunkCategory.paymentScreenshot => 'Payment receipts, grouped by app. Keep any you still need as proof.',
    JunkCategory.otherScreenshot =>
      'Screenshots of other apps and websites, grouped by what they show. None are pre-ticked.',
    JunkCategory.blurry => 'Photos too blurry to use. Ones with people in them are never pre-ticked.',
    JunkCategory.shortClip => 'Camera videos under 2 seconds, usually recorded by accident. Play them to check.',
    JunkCategory.screenRecording => 'Screen recordings, oldest first likely safe to remove.',
    JunkCategory.largeVideo => 'Very large videos. Not ticked: check whether you still need them on the phone.',
    JunkCategory.oldInstaller => 'App installer files. Installed apps keep working without them.',
    JunkCategory.oldVoiceNote => 'WhatsApp voice notes older than 3 months. Not ticked: some may matter to you.',
    JunkCategory.oldDocument => 'Downloads and WhatsApp documents untouched for 6+ months. Not ticked: check first.',
    JunkCategory.cacheFiles => 'Gallery previews and WhatsApp statuses you viewed. Rebuilt or expired automatically.',
  };
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.state, required this.group, required this.members});
  final _ReviewPageState state;
  final String? group;
  final List<_Entry> members;

  @override
  Widget build(BuildContext context) {
    final paths = members.map((e) => e.key).toList();
    final allPicked = paths.every(state.selection.has);
    final kept = group != null && group!.startsWith('keep:') ? state.byPath[group!.substring(5)] : null;
    return Container(
      padding: const EdgeInsets.only(bottom: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Tone.line)),
      ),
      child: Row(
        children: [
          if (kept != null) ...[
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Tone.ink, width: 1.5),
                borderRadius: BorderRadius.circular(3),
              ),
              child: FileThumb(file: kept, media: state.media, size: 44),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: kept != null ? 'Keeping ${kept.name}' : (group ?? 'Other'),
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  TextSpan(
                    text:
                        '    ${kept != null ? '${paths.length} ${paths.length == 1 ? 'copy' : 'copies'}' : '${paths.length}'}'
                        ' · ${formatBytes(state.bytesOf(paths))}',
                    style: Typed.factMuted,
                  ),
                ],
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => state.selection.setAll(paths, !allPicked),
            child: Text(allPicked ? 'Untick these' : 'Tick these'),
          ),
        ],
      ),
    );
  }
}

/// One suggestion: its picture, one typed reason, size and date in fixed
/// cells. Ticked cards carry the violet REMOVE stamp.
class _Card extends StatelessWidget {
  const _Card({required this.state, required this.entry});
  final _ReviewPageState state;
  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    final f = state.byPath[entry.key]!;
    final v = entry.value.verdict;
    final on = state.selection.has(entry.key);
    final focused = state.focused == entry.key;
    return Material(
      color: Tone.paper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(3),
        // Ink, not violet: violet only ever means "will be removed".
        side: BorderSide(color: focused ? Tone.ink : Tone.line, width: focused ? 2 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => state.focus(entry.key),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(height: 3, color: Tone.rule),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
              child: SizedBox(
                height: 180,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    FileThumb(file: f, media: state.media, fill: true),
                    // Bottom corner: never over what the user needs to read to decide.
                    if (on) const Positioned(left: 8, bottom: 10, child: IgnorePointer(child: RemoveStamp())),
                    Positioned(
                      right: 6,
                      top: 6,
                      child: TickBox(on: on, onTap: () => state.selection.toggle(entry.key)),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Text(shortReason(v), style: Typed.fact, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 0),
              child: Row(
                children: [
                  Expanded(child: Text(formatBytes(f.bytes), style: Typed.factMuted)),
                  Text(shortDate(f.modifiedSec), style: Typed.factMuted),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one reason a card shows: the most specific line, without the
/// generic "screenshot received from another app".
String shortReason(Verdict v) =>
    v.reasons.where((r) => !r.startsWith('Screenshot saved or received')).firstOrNull ??
    v.reasons.firstOrNull ??
    v.category.label;

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String shortDate(int sec) {
  final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

class _DetailHint extends StatelessWidget {
  const _DetailHint();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(32),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Pick a card to see it here', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        SizedBox(height: 8),
        Text(
          'Large, next to the copy it matched, with exactly why Declutter picked it.',
          style: TextStyle(color: Tone.muted, height: 1.45),
        ),
        SizedBox(height: 24),
        SlipRow('← → ↑ ↓', 'move between cards', labelWidth: 90, selectable: false),
        SlipRow('Space', 'tick or untick', labelWidth: 90, selectable: false),
        SlipRow('Ctrl+A', 'tick the whole group', labelWidth: 90, selectable: false),
        SlipRow('Esc', 'back', labelWidth: 90, selectable: false),
      ],
    ),
  );
}

/// The focused item, large: side by side with its match, the tick, and
/// the "How we know" slip.
class _Detail extends StatelessWidget {
  const _Detail({super.key, required this.state, required this.entry});
  final _ReviewPageState state;
  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    final f = state.byPath[entry.key]!;
    final v = entry.value.verdict;
    final match = entry.value.matchPath == null ? null : state.byPath[entry.value.matchPath];

    // Full panel width, one above the other: side by side they'd be too
    // small to tell which of two near-identical photos is sharper.
    Widget side(String label, PhoneFile file, {required bool keep}) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: keep ? Tone.ink : Tone.stamp),
          ),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: keep ? Tone.ink : Tone.stamp, width: 2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: MediaView(file: file, media: state.media, height: 280),
          ),
          const SizedBox(height: 6),
          Text(file.name, style: Typed.fact, overflow: TextOverflow.ellipsis),
          Text('${formatBytes(file.bytes)} · ${shortDate(file.modifiedSec)}', style: Typed.factMuted),
        ],
      ),
    );

    return ListenableBuilder(
      listenable: state.selection,
      builder: (context, _) {
        final on = state.selection.has(entry.key);
        return ListView(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 28),
          children: [
            Text(
              f.name,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              f.folder,
              style: const TextStyle(fontSize: 12, color: Tone.muted),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 14),
            if (match != null) ...[
              side('Keeping', match, keep: true),
              side(on ? 'Removing this copy' : 'This copy, kept', f, keep: !on),
            ] else ...[
              MediaView(key: GlobalObjectKey<MediaViewState>(f.path), file: f, media: state.media, height: 360),
              if (f.isVideo && state.media != null) ...[
                const SizedBox(height: 8),
                Filmstrip(
                  file: f,
                  media: state.media!,
                  onTapFrame: (p) => GlobalObjectKey<MediaViewState>(f.path).currentState?.play(from: p),
                ),
              ],
            ],
            const SizedBox(height: 14),
            Material(
              color: on ? Tone.stampTint : Tone.desk,
              borderRadius: BorderRadius.circular(4),
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () => state.selection.toggle(entry.key),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      TickBox(on: on, onTap: () => state.selection.toggle(entry.key)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              on ? 'Will be removed  (Space to keep)' : 'Kept  (Space to remove)',
                              style: TextStyle(fontWeight: FontWeight.w600, color: on ? Tone.stamp : Tone.ink),
                            ),
                            Text(
                              '${formatBytes(f.bytes)} · ${v.tier == Tier.sure ? 'Declutter is sure' : 'For you to check'}',
                              style: Typed.factMuted,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Slip(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('How we know', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  for (final (i, r) in v.reasons.where((r) => !r.startsWith('Screenshot saved or received')).indexed)
                    SlipRow(i == 0 ? 'Why' : '', r),
                  for (final MapEntry(key: k, value: val) in v.evidence.entries) SlipRow(k, val),
                  SlipRow('Where', f.folder),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
