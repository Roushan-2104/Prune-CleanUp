import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Encrypts text so only the current Windows user on this laptop can read
/// it back (Windows' Data Protection API — the same mechanism browsers use
/// for saved passwords). No key to manage: Windows ties it to the account.
///
/// Used for what Prune read off screenshots (chats, payments), which
/// would otherwise sit in the database as plain text.
abstract final class Dpapi {
  static const _prefix = 'dpapi1:';

  /// Whether [stored] is an encrypted value written by [protect].
  static bool isProtected(String stored) => stored.startsWith(_prefix);

  static String protect(String text) {
    final out = _call(utf8.encode(text), encrypt: true);
    return '$_prefix${base64.encode(out)}';
  }

  /// The original text; values written before encryption pass through.
  static String unprotect(String stored) {
    if (!isProtected(stored)) return stored;
    return utf8.decode(_call(base64.decode(stored.substring(_prefix.length)), encrypt: false));
  }

  static final _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _protectData = _crypt32.lookupFunction<_CryptC, _CryptDart>('CryptProtectData');
  static final _unprotectData = _crypt32.lookupFunction<_CryptC, _CryptDart>('CryptUnprotectData');
  static final _localFree =
      _kernel32.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');

  static const _uiForbidden = 0x1;

  static Uint8List _call(List<int> data, {required bool encrypt}) {
    if (!Platform.isWindows) throw UnsupportedError('DPAPI is Windows-only');
    final input = calloc<_Blob>(), output = calloc<_Blob>();
    final bytes = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    try {
      bytes.asTypedList(data.length).setAll(0, data);
      input.ref
        ..cbData = data.length
        ..pbData = bytes;
      final ok = (encrypt ? _protectData : _unprotectData)(input, nullptr, nullptr, nullptr, nullptr, _uiForbidden, output);
      if (ok == 0) throw StateError('Windows could not ${encrypt ? 'encrypt' : 'decrypt'} the data');
      final result = Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
      _localFree(output.ref.pbData.cast());
      return result;
    } finally {
      calloc
        ..free(bytes)
        ..free(input)
        ..free(output);
    }
  }
}

final class _Blob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptC = Int32 Function(
    Pointer<_Blob>, Pointer<Void>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _CryptDart = int Function(
    Pointer<_Blob>, Pointer<Void>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>);
