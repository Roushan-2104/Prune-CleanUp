/// Where a line of read text sits on a screenshot, as fractions of the
/// picture's width and height (0 = left/top edge, 1 = right/bottom edge).
class LineBox {
  const LineBox(this.left, this.top, this.width, this.height);
  final double left, top, width, height;

  double get right => left + width;
  double get bottom => top + height;
  double get middleY => top + height / 2;

  @override
  String toString() => 'LineBox($left, $top, $width, $height)';
}

/// Compact form for storage: "left,top,width,height;…", four decimals each.
/// Holds positions only, never any text.
String encodeBoxes(Iterable<(double, double, double, double)> boxes) => boxes
    .map((b) => [b.$1, b.$2, b.$3, b.$4].map((v) => v.clamp(0.0, 1.0).toStringAsFixed(4)).join(','))
    .join(';');

/// The other half of [encodeBoxes]; damaged entries become empty boxes so
/// the list still lines up with the text's lines.
List<LineBox> decodeBoxes(String encoded) {
  if (encoded.isEmpty) return const [];
  return [
    for (final part in encoded.split(';'))
      if (part.split(',').map(double.tryParse).toList() case [final l?, final t?, final w?, final h?])
        LineBox(l, t, w, h)
      else
        const LineBox(0, 0, 0, 0),
  ];
}
