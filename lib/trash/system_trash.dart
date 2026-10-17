import 'package:flutter/services.dart';

/// A photo sitting in Android's system Trash.
class TrashedPhoto {
  TrashedPhoto({required this.id, required this.name, required this.bytes, required this.expires});

  factory TrashedPhoto.fromMap(Map<Object?, Object?> m) => TrashedPhoto(
        id: m['id'] as String,
        name: (m['name'] as String?) ?? '',
        bytes: (m['bytes'] as num?)?.toInt() ?? 0,
        expires: DateTime.fromMillisecondsSinceEpoch(((m['expiresSec'] as num?)?.toInt() ?? 0) * 1000),
      );

  final String id;
  final String name;
  final int bytes;

  /// When Android deletes it for good (30 days after it was trashed).
  final DateTime expires;

  int get daysLeft => expires.difference(DateTime.now()).inDays.clamp(0, 30);
}

/// Talks to the native "saaf/trash" channel in MainActivity.kt (Android 11+).
class SystemTrash {
  static const _channel = MethodChannel('saaf/trash');
  static final _thumbs = <String, Uint8List>{};

  static Future<List<TrashedPhoto>> list() async {
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>('list') ?? [];
    return raw.map(TrashedPhoto.fromMap).toList();
  }

  static Future<Uint8List?> thumbnail(String id, {int size = 300}) async {
    if (_thumbs[id] case final cached?) return cached;
    final bytes = await _channel.invokeMethod<Uint8List>('thumbnail', {'id': id, 'size': size});
    if (bytes != null) _thumbs[id] = bytes;
    return bytes;
  }

  /// Puts photos back in the gallery. Android asks the user to confirm once.
  /// Returns false if they said no.
  static Future<bool> restore(List<String> ids) async =>
      await _channel.invokeMethod<bool>('restore', {'ids': ids}) ?? false;
}
