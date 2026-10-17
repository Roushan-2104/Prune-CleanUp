import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../app_state.dart';
import '../scan/scanner.dart';
import '../scan/verdict.dart';

/// Review screen for one category.
///
/// - Duplicates / similar photos: one group per kept photo. The kept photo is
///   shown first with a green "KEEPING" badge, followed by its copies.
/// - Other screenshots: one section per label (Instagram, Shopping, …).
/// - Everything else: "Sure junk" (pre-ticked) then "Please check these".
///
/// Long-press any photo to see why it was picked.
class CategoryScreen extends StatelessWidget {
  const CategoryScreen({super.key, required this.state, required this.category});
  final AppState state;
  final JunkCategory category;

  bool get _isDuplicates =>
      category == JunkCategory.exactDuplicate || category == JunkCategory.nearDuplicate;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final list = state.itemsIn(category);
        final chosen = list.where((i) => state.selected.contains(i.asset.id));
        final chosenBytes = state.bytesOf(chosen);

        return Scaffold(
          appBar: AppBar(title: Text(category.label), actions: [
            TextButton(
              onPressed: () => state.setAll(list, chosen.length != list.length),
              child: Text(chosen.length == list.length ? 'Unselect all' : 'Select all'),
            ),
          ]),
          body: CustomScrollView(slivers: [
            ..._isDuplicates ? _duplicateGroups(context, list) : _sections(context, list),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ]),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: chosen.isEmpty ? null : () => _trash(context),
                icon: const Icon(Icons.delete_outline),
                label: Text(chosen.isEmpty
                    ? 'Nothing selected'
                    : 'Move ${chosen.length} to Trash · ${formatBytes(chosenBytes)}'),
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _sections(BuildContext context, List<ScanItem> list) {
    if (category == JunkCategory.otherScreenshot) {
      final byLabel = <String, List<ScanItem>>{};
      for (final i in list) {
        byLabel.putIfAbsent(i.verdict.label ?? 'Other app screens', () => []).add(i);
      }
      final labels = byLabel.keys.toList()
        ..sort((a, b) => byLabel[b]!.length.compareTo(byLabel[a]!.length));
      return [for (final l in labels) ..._section(context, l, byLabel[l]!)];
    }
    final sure = list.where((i) => i.verdict.tier == Tier.sure).toList();
    final maybe = list.where((i) => i.verdict.tier == Tier.maybe).toList();
    return [
      if (sure.isNotEmpty) ..._section(context, 'Sure junk', sure),
      if (maybe.isNotEmpty) ..._section(context, 'Please check these', maybe),
    ];
  }

  List<Widget> _section(BuildContext context, String title, List<ScanItem> items) => [
        _header(context, '$title (${items.length})'),
        SliverGrid.builder(
          gridDelegate: _grid,
          itemCount: items.length,
          itemBuilder: (context, i) => _Tile(state: state, item: items[i]),
        ),
      ];

  List<Widget> _duplicateGroups(BuildContext context, List<ScanItem> list) {
    final groups = <String, List<ScanItem>>{};
    for (final i in list) {
      groups.putIfAbsent(i.match?.id ?? i.asset.id, () => []).add(i);
    }
    final what = category == JunkCategory.exactDuplicate ? 'exact copies' : 'similar photos';
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text('In each group we keep the best photo (green). '
              'The others are $what of it. Long-press any photo to compare.'),
        ),
      ),
      for (final (index, copies) in groups.values.indexed) ...[
        _header(context, 'Group ${index + 1} · ${copies.length} $what'),
        SliverGrid.list(gridDelegate: _grid, children: [
          if (copies.first.match case final kept?) _KeptTile(asset: kept),
          for (final c in copies) _Tile(state: state, item: c),
        ]),
      ],
    ];
  }

  Widget _header(BuildContext context, String text) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(text, style: Theme.of(context).textTheme.titleMedium),
        ),
      );

  static const _grid = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2);

  Future<void> _trash(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final moved = await state.trashSelected(category);
      if (moved.isEmpty) return;
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text('Moved ${moved.length} to Trash. Restore anytime within 30 days.'),
        action: SnackBarAction(label: 'UNDO', onPressed: () => state.undoTrash(moved)),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not move to Trash: $e')));
    }
  }
}

Widget _thumb(AssetEntity asset, {int size = 300, BoxFit fit = BoxFit.cover}) =>
    AssetEntityImage(asset, isOriginal: false, thumbnailSize: ThumbnailSize.square(size), fit: fit);

/// The photo we keep in a duplicate group. Never selectable.
class _KeptTile extends StatelessWidget {
  const _KeptTile({required this.asset});
  final AssetEntity asset;

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      _thumb(asset),
      Container(decoration: BoxDecoration(border: Border.all(color: Colors.green, width: 4))),
      Positioned(
        left: 4,
        bottom: 4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(4)),
          child: const Text('KEEPING', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
        ),
      ),
    ]);
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.state, required this.item});
  final AppState state;
  final ScanItem item;

  @override
  Widget build(BuildContext context) {
    final isSelected = state.selected.contains(item.asset.id);
    return GestureDetector(
      onTap: () => state.toggle(item.asset.id),
      onLongPress: () => _showDetails(context),
      child: Stack(fit: StackFit.expand, children: [
        _thumb(item.asset),
        if (isSelected) Container(color: Colors.black26),
        Positioned(
          top: 6,
          right: 6,
          child: Icon(isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: isSelected ? Colors.redAccent : Colors.white),
        ),
      ]),
    );
  }

  void _showDetails(BuildContext context) {
    final pay = item.payment;
    final match = item.match;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (match == null)
              AspectRatio(aspectRatio: 1, child: _thumb(item.asset, size: 800, fit: BoxFit.contain))
            else
              Row(children: [
                Expanded(child: _Labeled('This photo', Colors.redAccent, _thumb(item.asset, size: 600, fit: BoxFit.contain))),
                const SizedBox(width: 8),
                Expanded(child: _Labeled('Keeping this one', Colors.green, _thumb(match, size: 600, fit: BoxFit.contain))),
              ]),
            const SizedBox(height: 12),
            if (item.verdict.label != null) Text(item.verdict.label!, style: Theme.of(context).textTheme.titleMedium),
            Text('Why: ${item.verdict.reasons.join(' · ')}'),
            Text('Confidence: ${(item.verdict.confidence * 100).round()}% · ${formatBytes(item.bytes)}'),
            if (pay != null && (pay.amount != null || pay.payee != null))
              Text('Payment: ${pay.amount != null ? '₹${pay.amount}' : ''} ${pay.payee ?? ''}'),
          ]),
        ),
      ),
    );
  }
}

class _Labeled extends StatelessWidget {
  const _Labeled(this.label, this.color, this.child);
  final String label;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      AspectRatio(
        aspectRatio: 0.75,
        child: DecoratedBox(
          decoration: BoxDecoration(border: Border.all(color: color, width: 3)),
          child: child,
        ),
      ),
    ]);
  }
}
