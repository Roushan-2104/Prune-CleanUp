import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../app_state.dart';
import '../scan/scanner.dart';
import '../scan/verdict.dart';
import 'accuracy_screen.dart';
import 'category_screen.dart';
import 'trash_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Saaf'), actions: [
        IconButton(
          tooltip: 'Trash',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => TrashScreen(state: state))),
        ),
        IconButton(
          tooltip: 'Accuracy test',
          icon: const Icon(Icons.fact_check_outlined),
          onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => AccuracyScreen(state: state))),
        ),
      ]),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => switch (state.status) {
          ScanStatus.idle => _Intro(onScan: state.startScan),
          ScanStatus.noPermission => _NoPermission(onRetry: state.startScan),
          ScanStatus.scanning => _Scanning(progress: state.progress),
          ScanStatus.done => _Results(state: state),
        },
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro({required this.onScan});
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cleaning_services_outlined, size: 72),
          const SizedBox(height: 16),
          Text('Find junk photos in seconds', style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const Text('Payment & chat screenshots, blurry shots and duplicates. '
              'Everything is checked on your phone — nothing is uploaded.', textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton.icon(onPressed: onScan, icon: const Icon(Icons.search), label: const Text('Scan my photos')),
        ]),
      ),
    );
  }
}

class _NoPermission extends StatelessWidget {
  const _NoPermission({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Saaf needs access to your photos to find junk.', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: PhotoManager.openSetting, child: const Text('Open settings')),
          TextButton(onPressed: onRetry, child: const Text('Try again')),
        ]),
      ),
    );
  }
}

class _Scanning extends StatelessWidget {
  const _Scanning({required this.progress});
  final ScanProgress progress;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final finishing = p.toCheck > 0 && p.done == p.toCheck;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(value: p.toCheck == 0 || finishing ? null : p.done / p.toCheck),
          const SizedBox(height: 16),
          Text(switch (p) {
            _ when finishing => 'Sorting results…',
            ScanProgress(toCheck: 0, alreadyChecked: > 0) => 'No new photos — updating results…',
            ScanProgress(toCheck: 0) => 'Getting ready…',
            _ => 'Checking ${p.done} of ${p.toCheck} new photos',
          }),
          if (p.alreadyChecked > 0) ...[
            const SizedBox(height: 4),
            Text('${p.alreadyChecked} photos already checked earlier — skipped',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ]),
      ),
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final categories = JunkCategory.values.where((c) => state.itemsIn(c).isNotEmpty).toList();
    if (categories.isEmpty) {
      return const Center(child: Text('Your gallery looks clean! 🎉'));
    }
    final theme = Theme.of(context);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('You can free', style: theme.textTheme.titleMedium),
      Text(formatBytes(state.bytesOf(state.items)), style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      for (final c in categories) _CategoryCard(state: state, category: c),
      const SizedBox(height: 8),
      TextButton.icon(onPressed: state.startScan, icon: const Icon(Icons.refresh), label: const Text('Check for new photos')),
    ]);
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.state, required this.category});
  final AppState state;
  final JunkCategory category;

  @override
  Widget build(BuildContext context) {
    final list = state.itemsIn(category);
    final sure = list.where((i) => i.verdict.tier == Tier.sure).length;
    final maybe = list.length - sure;
    return Card(
      child: ListTile(
        title: Text(category.label),
        subtitle: Text([
          if (sure > 0) '$sure sure',
          if (maybe > 0) '$maybe to check',
        ].join(' · ')),
        trailing: Text(formatBytes(state.bytesOf(list))),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => CategoryScreen(state: state, category: category),
        )),
      ),
    );
  }
}
