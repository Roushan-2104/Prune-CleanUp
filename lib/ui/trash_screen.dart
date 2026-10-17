import 'package:flutter/material.dart';

import '../app_state.dart';
import '../trash/system_trash.dart';

/// Shows photos in the phone's Trash with days left, and restores the ticked ones.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key, required this.state});
  final AppState state;

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  late Future<List<TrashedPhoto>> _photos = SystemTrash.list();
  final _selected = <String>{};

  Future<void> _restore() async {
    final messenger = ScaffoldMessenger.of(context);
    final ids = _selected.toList();
    try {
      if (!await SystemTrash.restore(ids)) return;
      messenger.showSnackBar(SnackBar(content: Text('Restored ${ids.length} to your gallery')));
      setState(() {
        _selected.clear();
        _photos = SystemTrash.list();
      });
      widget.state.startScan();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not restore: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trash')),
      body: FutureBuilder(
        future: _photos,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text('Could not open Trash: ${snap.error}', textAlign: TextAlign.center),
            ));
          }
          final photos = snap.data;
          if (photos == null) return const Center(child: CircularProgressIndicator());
          if (photos.isEmpty) return const Center(child: Text('Trash is empty'));

          final allSelected = _selected.length == photos.length;
          return CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                child: Row(children: [
                  Expanded(child: Text(
                    '${photos.length} photos · ${formatBytes(photos.fold(0, (s, p) => s + p.bytes))}\n'
                    'Android deletes them for good when the days run out.',
                  )),
                  TextButton(
                    onPressed: () => setState(() => allSelected
                        ? _selected.clear()
                        : _selected.addAll(photos.map((p) => p.id))),
                    child: Text(allSelected ? 'Unselect all' : 'Select all'),
                  ),
                ]),
              ),
            ),
            SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2),
              itemCount: photos.length,
              itemBuilder: (context, i) => _TrashTile(
                photo: photos[i],
                selected: _selected.contains(photos[i].id),
                onTap: () => setState(() => _selected.contains(photos[i].id)
                    ? _selected.remove(photos[i].id)
                    : _selected.add(photos[i].id)),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ]);
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _selected.isEmpty ? null : _restore,
            icon: const Icon(Icons.restore),
            label: Text(_selected.isEmpty ? 'Select photos to restore' : 'Restore ${_selected.length}'),
          ),
        ),
      ),
    );
  }
}

class _TrashTile extends StatelessWidget {
  const _TrashTile({required this.photo, required this.selected, required this.onTap});
  final TrashedPhoto photo;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(fit: StackFit.expand, children: [
        FutureBuilder(
          future: SystemTrash.thumbnail(photo.id),
          builder: (context, snap) => snap.data == null
              ? const ColoredBox(color: Colors.black12)
              : Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
        ),
        if (selected) Container(color: Colors.black26),
        Positioned(
          top: 6,
          right: 6,
          child: Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: selected ? Colors.green : Colors.white),
        ),
        Positioned(
          left: 4,
          bottom: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
            child: Text('${photo.daysLeft} days left',
                style: const TextStyle(color: Colors.white, fontSize: 11)),
          ),
        ),
      ]),
    );
  }
}
