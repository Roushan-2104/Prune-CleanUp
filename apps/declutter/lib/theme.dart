import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Prune's look, "Night archive": a dark gallery where the phone's photos
/// hang like a collection. Near-black walls, dark cards, bone-white type,
/// and the logo's violet band for exactly one meaning: will be removed
/// (ticks, the REMOVE stamp, the cut in the storage bar, the Clean button).
/// Reasons and facts are typed.
abstract final class Tone {
  static const desk = Color(0xFF16151A); // the walls behind everything
  static const paper = Color(0xFF24222A); // cards, rail, panels
  static const check = Color(0xFF1D1B22); // cards for you to check (not pre-ticked)
  static const ink = Color(0xFFEDE9E1); // bone-white type, 14:1 on the walls
  static const muted = Color(0xFF9C978C); // secondary text, 5.6:1 on cards
  static const line = Color(0xFF34313B); // card and panel edges
  static const ruling = Color(0xFF2C2A33); // faint lines between rows of a slip
  static const rule = Color(0xFF34313B); // the top edge of bars and slips
  static const stamp = Color(0xFF9B7BE0); // violet: selected, to be removed
  static const onStamp = Color(0xFF16151A); // text and ticks on violet
  static const stampTint = Color(0xFF2E2640); // a violet wash behind a ticked item
  static const highlight = Color(0xFFC7B3F2); // the freeable figure on Home
  static const danger = Color(0xFFE5736A); // errors
  static const blank = Color(0xFF1D1B22); // an empty picture frame
}

/// Typed text: reasons, sizes, dates, evidence. One size for every item
/// fact; rank comes from weight and ink, never size.
abstract final class Typed {
  static const family = 'Consolas';
  static const fact = TextStyle(fontFamily: family, fontSize: 12.5, height: 1.35, color: Tone.ink);
  static TextStyle get factMuted => fact.copyWith(color: Tone.muted);
  static TextStyle get factBold => fact.copyWith(fontWeight: FontWeight.w700);
}

ThemeData pruneTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: Tone.stamp, brightness: Brightness.dark).copyWith(
    primary: Tone.stamp,
    onPrimary: Tone.onStamp,
    secondary: Tone.muted,
    onSecondary: Tone.desk,
    surface: Tone.paper,
    onSurface: Tone.ink,
    onSurfaceVariant: Tone.muted,
    surfaceContainerLowest: Tone.paper,
    surfaceContainerLow: Tone.desk,
    surfaceContainer: Tone.desk,
    surfaceContainerHigh: Tone.blank,
    surfaceContainerHighest: Tone.blank,
    outline: Tone.line,
    outlineVariant: Tone.line,
    error: Tone.danger,
    onError: Tone.desk,
    errorContainer: const Color(0xFF3A2224),
    onErrorContainer: const Color(0xFFF2B8B2),
    primaryContainer: Tone.stampTint,
    onPrimaryContainer: Tone.highlight,
    secondaryContainer: Tone.stampTint,
    onSecondaryContainer: Tone.ink,
  );
  final base = ThemeData(useMaterial3: true, brightness: Brightness.dark, colorScheme: scheme, fontFamily: 'Segoe UI');
  return base.copyWith(
    scaffoldBackgroundColor: Tone.desk,
    dividerTheme: const DividerThemeData(color: Tone.line, thickness: 1, space: 1),
    textTheme: base.textTheme.apply(bodyColor: Tone.ink, displayColor: Tone.ink),
    textSelectionTheme: TextSelectionThemeData(
      selectionColor: Tone.stamp.withValues(alpha: 0.18),
      cursorColor: Tone.stamp,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(Tone.ink.withValues(alpha: 0.22)),
      radius: const Radius.circular(3),
      thickness: const WidgetStatePropertyAll(6),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Tone.stamp,
        foregroundColor: Tone.onStamp,
        disabledBackgroundColor: Tone.line,
        disabledForegroundColor: Tone.muted,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Tone.stamp,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(foregroundColor: Tone.ink, side: const BorderSide(color: Tone.line)),
    ),
    iconTheme: const IconThemeData(color: Tone.ink),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Tone.ink,
      contentTextStyle: TextStyle(color: Tone.desk, fontSize: 13),
      actionTextColor: Color(0xFF5B3C8C),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Tone.stamp : Tone.paper),
      side: const BorderSide(color: Tone.muted, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: Tone.stamp, linearTrackColor: Tone.line),
    dialogTheme: DialogThemeData(
      backgroundColor: Tone.paper,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: Tone.ink, borderRadius: BorderRadius.circular(4)),
      textStyle: const TextStyle(color: Tone.desk, fontSize: 12),
    ),
  );
}

/// A catalog slip: paper with the red top rule, faint ruling between rows.
class Slip extends StatelessWidget {
  const Slip({super.key, required this.child, this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 14)});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: Tone.paper,
      border: Border(
        top: BorderSide(color: Tone.rule, width: 2),
        left: BorderSide(color: Tone.line),
        right: BorderSide(color: Tone.line),
        bottom: BorderSide(color: Tone.line),
      ),
    ),
    padding: padding,
    child: child,
  );
}

/// One typed line of a slip: "Chat with   Nikhil".
class SlipRow extends StatelessWidget {
  const SlipRow(this.label, this.value, {super.key, this.labelWidth = 130, this.selectable = true, this.prose = false});
  final String label;
  final String value;
  final double labelWidth;
  final bool selectable;

  /// A sentence (set in the interface face) rather than a typed fact.
  final bool prose;

  @override
  Widget build(BuildContext context) {
    final style = prose ? const TextStyle(fontSize: 14, height: 1.4, color: Tone.ink) : Typed.fact;
    return Container(
      padding: EdgeInsets.symmetric(vertical: prose ? 8 : 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Tone.ruling)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(label, style: prose ? style.copyWith(fontWeight: FontWeight.w700) : Typed.factBold),
          ),
          Expanded(
            child: selectable ? SelectableText(value, style: style) : Text(value, style: style),
          ),
        ],
      ),
    );
  }
}

/// The violet REMOVE stamp pressed onto a ticked card, slightly askew.
class RemoveStamp extends StatelessWidget {
  const RemoveStamp({super.key});

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: -8 * math.pi / 180,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Tone.paper.withValues(alpha: 0.85),
        border: Border.all(color: Tone.stamp.withValues(alpha: 0.9), width: 1.5),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text('REMOVE', style: Typed.factBold.copyWith(fontSize: 12, letterSpacing: 1.6, color: Tone.stamp)),
    ),
  );
}

/// The phone's storage as "the cut": what stays in grey, and the part the
/// current pick would free in violet at the end, marked off by a dashed
/// pruning cut. As picks change, the cut slides along the bar.
class CapacityBar extends StatelessWidget {
  const CapacityBar({super.key, required this.total, required this.used, required this.picked, this.height = 10});
  final int total, used, picked;
  final double height;

  static const _stays = Color(0xFF6E6A78);

  @override
  Widget build(BuildContext context) {
    final u = total == 0 ? 0.0 : (used / total).clamp(0.0, 1.0);
    final p = total == 0 ? 0.0 : (picked / total).clamp(0.0, u);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, c) => Stack(
            children: [
              Container(color: Tone.line),
              Container(width: c.maxWidth * u, color: _stays),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutCubic,
                left: c.maxWidth * (u - p),
                width: c.maxWidth * p,
                top: 0,
                bottom: 0,
                child: p == 0
                    ? const SizedBox.shrink()
                    : CustomPaint(
                        foregroundPainter: _CutLine(),
                        child: Container(color: Tone.stamp),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The dashed pruning cut at the left edge of the violet part.
class _CutLine extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Tone.desk
      ..strokeWidth = 2;
    for (var y = 0.0; y < size.height; y += 4) {
      canvas.drawLine(Offset(1, y), Offset(1, (y + 2).clamp(0, size.height)), paint);
    }
  }

  @override
  bool shouldRepaint(_CutLine old) => false;
}

/// The checkbox on a card: a small violet square when ticked.
class TickBox extends StatelessWidget {
  const TickBox({super.key, required this.on, required this.onTap});
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    checked: on,
    button: true,
    label: on ? 'Will be removed' : 'Kept',
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: on ? Tone.stamp : Tone.paper,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: on ? Tone.stamp : Tone.muted, width: 1.5),
        ),
        child: on ? const Icon(Icons.check, size: 16, color: Tone.onStamp) : null,
      ),
    ),
  );
}
