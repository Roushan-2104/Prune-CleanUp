import 'package:flutter/material.dart';

import 'phone_session.dart';
import 'theme.dart';

/// The bar across the top of every screen: the phone, its storage with the
/// current pick shown in violet, and the screen's main action.
class TopBar extends StatelessWidget {
  const TopBar({super.key, required this.session, this.picked = 0, this.leading, this.action});
  final PhoneSession session;

  /// Bytes the current pick would free (drawn in violet on the storage bar).
  final int picked;
  final Widget? leading;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final info = session.info;
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: Tone.desk,
        border: Border(bottom: BorderSide(color: Tone.line)),
      ),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 8)],
          const Text('Prune', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          const _ReadOnly(),
          if (info != null) ...[
            const SizedBox(width: 28),
            Text('${info.brand} ${info.model}', style: const TextStyle(color: Tone.muted)),
            const SizedBox(width: 20),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Built from "free" alone so the figures always add up
                    // (Android reserves some space that is neither used nor free).
                    CapacityBar(total: info.totalBytes, used: info.totalBytes - info.freeBytes, picked: picked),
                    const SizedBox(height: 4),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: '${formatBytes(info.freeBytes)} free'),
                          if (picked > 0) ...[
                            const TextSpan(text: '  ·  '),
                            TextSpan(
                              text: '${formatBytes(picked)} picked',
                              style: const TextStyle(color: Tone.stamp, fontWeight: FontWeight.w600),
                            ),
                            TextSpan(text: '  ·  ${formatBytes(info.freeBytes + picked)} free after'),
                          ] else
                            TextSpan(text: ' of ${formatBytes(info.totalBytes)}'),
                        ],
                      ),
                      style: const TextStyle(fontSize: 12, color: Tone.muted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ],
          const Spacer(),
          ?action,
        ],
      ),
    );
  }
}

class _ReadOnly extends StatelessWidget {
  const _ReadOnly();

  @override
  Widget build(BuildContext context) => const Tooltip(
    message: 'Prune only reads your phone. Nothing changes until you press Clean and confirm.',
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.lock_outline, size: 14, color: Tone.muted),
        SizedBox(width: 4),
        Text('Reads only, until you clean', style: TextStyle(fontSize: 12, color: Tone.muted)),
      ],
    ),
  );
}
