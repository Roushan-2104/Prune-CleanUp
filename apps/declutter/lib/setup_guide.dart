import 'package:flutter/material.dart';

import 'phone_session.dart';
import 'theme.dart';
import 'usb_presence.dart';

/// Getting a phone connected: what Prune sees right now, the steps for the
/// user's phone brand, and why USB debugging is safe to turn on.
///
/// Turning on USB debugging is where people give up, so the guide names the
/// exact menus per brand (and the blockers some makers add, like Samsung's
/// Auto Blocker) and says plainly what is missing: a charge-only cable, or
/// debugging still off.
class SetupGuide extends StatefulWidget {
  const SetupGuide({super.key, required this.session});
  final PhoneSession session;

  @override
  State<SetupGuide> createState() => _SetupGuideState();
}

class _SetupGuideState extends State<SetupGuide> {
  String? _chosen; // the user's pick; otherwise the brand USB suggests

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final asking = s.state == LinkState.unauthorized;
    final brand = _brands.firstWhere(
      (b) => b.key == (_chosen ?? s.onUsb.brand ?? 'other'),
      orElse: () => _brands.last,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(40, 36, 40, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                asking ? 'Allow this laptop on your phone' : 'Connect your Android phone',
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.4),
              ),
              if (!asking) ...[
                const SizedBox(height: 6),
                const Text(
                  'Your phone is hiding gigabytes. Prune finds them, and shows proof for every pick.',
                  style: TextStyle(fontSize: 15, color: Tone.muted, height: 1.4),
                ),
              ],
              const SizedBox(height: 14),
              _Status(look: asking ? null : s.onUsb),
              const SizedBox(height: 22),
              if (asking)
                const _Steps(
                  steps: [
                    'Unlock your phone and look at its screen.',
                    'Tap "Allow" on "Allow USB debugging?". Tick "Always allow from this computer" to skip this next time.',
                    'No message? Unplug and plug in again. Still nothing: in Developer options, tap "Revoke USB debugging '
                        'authorisations", then plug in again.',
                  ],
                )
              else ...[
                const Text('Your phone', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final b in _brands)
                      ChoiceChip(
                        label: Text(b.name),
                        selected: b.key == brand.key,
                        onSelected: (_) => setState(() => _chosen = b.key),
                        showCheckmark: false,
                        labelStyle: TextStyle(color: b.key == brand.key ? Tone.desk : Tone.ink, fontSize: 13),
                        selectedColor: Tone.ink,
                        backgroundColor: Tone.paper,
                        side: const BorderSide(color: Tone.line),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                _Steps(steps: [...brand.steps, ..._plugIn]),
                const SizedBox(height: 6),
                Text('Menu names can differ a little between versions.', style: Typed.factMuted),
              ],
              const SizedBox(height: 22),
              const _WhySafe(),
            ],
          ),
        ),
      ),
    );
  }
}

/// One line on what Prune can see right now, so nobody waits on a cable
/// that only charges.
class _Status extends StatelessWidget {
  const _Status({required this.look});
  final UsbPresence? look;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String text) = switch (look?.look) {
      null => (Icons.phone_android, 'Prune can see your phone. It is waiting for your permission.'),
      UsbLook.phone => (
        Icons.usb,
        'Your phone is plugged in, but USB debugging is still off (or blocked). Follow the steps below.',
      ),
      UsbLook.nothing => (
        Icons.cable,
        'No phone on USB yet. If it is plugged in, try a cable that carries data (many charging cables don\'t), '
            'another USB port, and unlock the phone.',
      ),
      UsbLook.unknown => (Icons.search, 'Waiting for your phone…'),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Tone.paper,
        border: Border.all(color: Tone.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Icon(icon, size: 18, color: Tone.muted),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14, height: 1.4))),
        ],
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.steps});
  final List<String> steps;

  @override
  Widget build(BuildContext context) => Slip(
    padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
    child: Column(
      children: [for (final (i, s) in steps.indexed) SlipRow('${i + 1}', s, labelWidth: 32, selectable: false, prose: true)],
    ),
  );
}

class _WhySafe extends StatelessWidget {
  const _WhySafe();

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Icon(Icons.verified_user_outlined, size: 18, color: Tone.muted),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          'Why this is safe: USB debugging is Android\'s own connection for computers. Prune installs nothing on '
          'your phone and changes nothing until you press Clean. You can turn USB debugging off again when '
          'you\'re done.',
          style: const TextStyle(fontSize: 13, color: Tone.muted, height: 1.5),
        ),
      ),
    ],
  );
}

/// The last steps for every phone.
const _plugIn = [
  'Plug the phone into this laptop with a USB cable that carries data.',
  'Unlock the phone and tap "Allow" on "Allow USB debugging?".',
];

/// Where each maker hides the two settings.
const _brands = <({String key, String name, List<String> steps})>[
  (
    key: 'samsung',
    name: 'Samsung',
    steps: [
      'Settings → About phone → Software information → tap "Build number" 7 times.',
      'If Auto Blocker is on, it blocks USB debugging: Settings → Security and privacy → Auto Blocker → turn it off '
          'while you use Prune.',
      'Settings → Developer options → turn on "USB debugging".',
    ],
  ),
  (
    key: 'xiaomi',
    name: 'Xiaomi, Redmi, POCO',
    steps: [
      'Settings → About phone → tap "OS version" (or "MIUI version") 7 times.',
      'Settings → Additional settings → Developer options → turn on "USB debugging".',
    ],
  ),
  (
    key: 'pixel',
    name: 'Google Pixel',
    steps: [
      'Settings → About phone → tap "Build number" 7 times.',
      'Settings → System → Developer options → turn on "USB debugging".',
    ],
  ),
  (
    key: 'oneplus',
    name: 'OnePlus, OPPO, realme',
    steps: [
      'Settings → About device → Version → tap "Build number" 7 times.',
      'Settings → System settings (or Additional settings) → Developer options → turn on "USB debugging".',
    ],
  ),
  (
    key: 'nothing',
    name: 'Nothing',
    steps: [
      'Settings → About phone → tap "Build number" 7 times.',
      'Settings → System → Developer options → turn on "USB debugging".',
    ],
  ),
  (
    key: 'motorola',
    name: 'Motorola',
    steps: [
      'Settings → About phone → tap "Build number" 7 times.',
      'Settings → System → Developer options → turn on "USB debugging".',
    ],
  ),
  (
    key: 'vivo',
    name: 'vivo, iQOO',
    steps: [
      'Settings → About phone → Software version → tap "Software version" 7 times.',
      'Settings → System management (or More settings) → Developer options → turn on "USB debugging".',
    ],
  ),
  (
    key: 'other',
    name: 'Other',
    steps: [
      'Settings → About phone → find "Build number" (sometimes under Software information) and tap it 7 times.',
      'Settings → search "Developer options" → turn on "USB debugging".',
    ],
  ),
];
