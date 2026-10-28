import 'package:flutter/material.dart';

import 'feedback.dart' show openInBrowser;
import 'theme.dart';
import 'updates.dart';

/// A quiet line under the top bar: asks once whether Prune may check for
/// new versions, and later says when one is out. Nothing otherwise.
class UpdateBar extends StatelessWidget {
  const UpdateBar({super.key, required this.check});
  final UpdateCheck check;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: check,
    builder: (context, _) {
      if (check.allowed == null) {
        return _Line(
          icon: Icons.update,
          text: 'Check GitHub for new versions of Prune? It only asks which version is newest, once a day. '
              'Nothing about you or your phone is sent.',
          actions: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Tone.muted),
              onPressed: () => check.allow(false),
              child: const Text('No thanks'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Tone.ink,
                foregroundColor: Tone.desk,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
              onPressed: () => check.allow(true),
              child: const Text('Yes, check'),
            ),
          ],
        );
      }
      final v = check.newer, url = check.newerUrl;
      if (v == null || url == null) return const SizedBox.shrink();
      return _Line(
        icon: Icons.system_update_alt,
        text: 'Prune $v is available. Install it over this one: your results and backups stay.',
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Tone.ink,
              foregroundColor: Tone.desk,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            onPressed: () => openInBrowser(url),
            child: const Text('Get it'),
          ),
        ],
      );
    },
  );
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text, required this.actions});
  final IconData icon;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(24, 8, 16, 8),
    decoration: const BoxDecoration(
      color: Tone.paper,
      border: Border(bottom: BorderSide(color: Tone.line)),
    ),
    child: Row(
      children: [
        Icon(icon, size: 18, color: Tone.muted),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.4))),
        const SizedBox(width: 12),
        for (final (i, a) in actions.indexed) ...[if (i > 0) const SizedBox(width: 8), a],
      ],
    ),
  );
}
