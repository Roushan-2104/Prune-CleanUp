/// Prune's local database on the laptop: which phones were connected,
/// what files they hold, what was measured about each file, and the history
/// of clean-ups. One SQLite file; nothing leaves the laptop.
library;

import 'dart:io';

import 'package:declutter_engine/declutter_engine.dart';
import 'package:phone_link/phone_link.dart';
import 'package:sqlite3/sqlite3.dart';

import 'src/dpapi.dart';

export 'src/dpapi.dart' show Dpapi;

/// How a phone's file list changed since the last time it was connected.
class InventoryDiff {
  const InventoryDiff({required this.added, required this.changed, required this.removed, required this.unchanged});
  final int added;
  final int changed;
  final int removed;
  final int unchanged;

  @override
  String toString() => 'InventoryDiff(+$added ~$changed -$removed =$unchanged)';
}

/// How a file leaves the phone: into the phone's own Trash (restorable for
/// 30 days on the phone), or deleted (restorable only from a laptop backup).
enum CleanMethod { trash, delete }

enum OpState { planned, done, failed, restored }

class PlannedOp {
  const PlannedOp(this.path, this.bytes, this.method, {this.backup, this.mediaId});
  final String path;
  final int bytes;
  final CleanMethod method;

  /// Android's media id, needed to take a file back out of the phone's Trash.
  final String? mediaId;

  /// Where the laptop backup of this file is, if one was made.
  final String? backup;
}

/// One journal entry.
class CleanOp {
  CleanOp._(Row r)
      : id = r['id'] as int,
        session = r['session'] as int,
        path = r['path'] as String,
        mediaId = r['media_id'] as String?,
        bytes = r['bytes'] as int,
        method = CleanMethod.values.byName(r['method'] as String),
        backup = r['backup'] as String?,
        state = OpState.values.byName(r['state'] as String),
        error = r['error'] as String?;

  final int id;
  final int session;
  final String path;
  final String? mediaId;
  final int bytes;
  final CleanMethod method;
  final String? backup;
  final OpState state;
  final String? error;
}

class Store {
  Store._(this._db, {required this.protectText}) {
    _migrate();
  }

  /// Opens (or creates) the database file at [path]. Text read off
  /// screenshots is stored encrypted for the current Windows user.
  factory Store.open(String path) => Store._(sqlite3.open(path), protectText: Platform.isWindows);
  factory Store.inMemory() => Store._(sqlite3.openInMemory(), protectText: false);

  final Database _db;

  /// Whether screenshot text is encrypted at rest (see [Dpapi]).
  final bool protectText;
  static const _schemaVersion = 6;

  void _migrate() {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA journal_mode = WAL'); // safe if the app is closed mid-write
    _db.execute('PRAGMA secure_delete = ON'); // deleted rows are overwritten, not just unlinked
    final version = _db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (version >= _schemaVersion) return;
    if (version < 1) _createV1();
    if (version < 2) {
      // The clean-up journal: every change to a phone is written here BEFORE
      // it happens, then marked done/failed, so an interruption can always be
      // finished or undone.
      _db.execute('''
        CREATE TABLE IF NOT EXISTS clean_ops (
          id INTEGER PRIMARY KEY,
          session INTEGER NOT NULL REFERENCES sessions (id),
          phone TEXT NOT NULL, path TEXT NOT NULL, media_id TEXT, bytes INTEGER NOT NULL,
          method TEXT NOT NULL CHECK (method IN ('trash', 'delete')),
          backup TEXT,
          state TEXT NOT NULL CHECK (state IN ('planned', 'done', 'failed', 'restored')),
          error TEXT, at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS clean_ops_by_session ON clean_ops (session);
      ''');
    }
    if (version < 3) {
      // Orientation, so similar photos are only compared portrait-to-portrait.
      final has = _db.select('PRAGMA table_info(measurements)').any((c) => c['name'] == 'landscape');
      if (!has) _db.execute('ALTER TABLE measurements ADD COLUMN landscape INTEGER');
    }
    if (version < 5) {
      // Content fingerprints (MD5, computed on the phone), kept while the file
      // is unchanged so the phone isn't asked again on every connection.
      _db.execute('''
        CREATE TABLE IF NOT EXISTS fingerprints (
          phone TEXT NOT NULL, path TEXT NOT NULL,
          modified_sec INTEGER NOT NULL, bytes INTEGER NOT NULL, md5 TEXT NOT NULL,
          PRIMARY KEY (phone, path),
          FOREIGN KEY (phone, path) REFERENCES files (phone, path) ON DELETE CASCADE
        ) WITHOUT ROWID;
      ''');
    }
    if (version < 6) {
      // Where each line of a screenshot's text sits (positions only, no
      // text), so chat names can be read from the screen's layout.
      final has = _db.select('PRAGMA table_info(measurements)').any((c) => c['name'] == 'boxes');
      if (!has) _db.execute('ALTER TABLE measurements ADD COLUMN boxes TEXT');
    }
    var vacuum = false;
    if (version < 4 && protectText) {
      // Encrypt text saved before encryption existed, then rebuild the file
      // so no plain copy survives in free pages.
      final rows = _db.select("SELECT phone, path, text FROM measurements WHERE text IS NOT NULL AND text <> ''");
      _transaction(() {
        final put = _db.prepare('UPDATE measurements SET text = ? WHERE phone = ? AND path = ?');
        try {
          for (final r in rows) {
            final t = r['text'] as String;
            if (!Dpapi.isProtected(t)) put.execute([Dpapi.protect(t), r['phone'], r['path']]);
          }
        } finally {
          put.close();
        }
      });
      vacuum = rows.isNotEmpty;
    }
    _db.execute('PRAGMA user_version = $_schemaVersion');
    if (vacuum) _scrubFile();
  }

  /// Rewrites the database file so deleted or replaced data is gone from it,
  /// including the write-ahead log.
  void _scrubFile() {
    _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    _db.execute('VACUUM');
    _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  }

  /// Removes everything Prune knows about a phone from this laptop:
  /// its file list, measurements and screenshot text, and clean-up history.
  /// (Backup copies in "Prune Backups" are the user's files and stay.)
  void forgetPhone(String serial) {
    _transaction(() {
      _db.execute('DELETE FROM fingerprints WHERE phone = ?', [serial]);
      _db.execute('DELETE FROM clean_ops WHERE phone = ?', [serial]);
      _db.execute('DELETE FROM sessions WHERE phone = ?', [serial]);
      _db.execute('DELETE FROM measurements WHERE phone = ?', [serial]);
      _db.execute('DELETE FROM files WHERE phone = ?', [serial]);
      _db.execute('DELETE FROM phones WHERE serial = ?', [serial]);
    });
    _textCache.clear();
    _scrubFile();
  }

  String? _seal(String? text) =>
      text == null || text.isEmpty || !protectText ? text : Dpapi.protect(text);

  // Decrypting is cheap but not free; the same rows are read after every
  // photo-check batch.
  final _textCache = <String, String>{};
  String? _open(String? stored) =>
      stored == null || !Dpapi.isProtected(stored) ? stored : _textCache[stored] ??= Dpapi.unprotect(stored);

  void _createV1() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS phones (
        serial TEXT PRIMARY KEY,
        brand TEXT, model TEXT, android TEXT,
        first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS files (
        phone TEXT NOT NULL, path TEXT NOT NULL,
        media_id TEXT, folder TEXT NOT NULL, bytes INTEGER NOT NULL, mime TEXT NOT NULL,
        modified_sec INTEGER NOT NULL, taken_ms INTEGER, width INTEGER, height INTEGER, duration_ms INTEGER,
        first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL,
        PRIMARY KEY (phone, path)
      ) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS measurements (
        phone TEXT NOT NULL, path TEXT NOT NULL,
        modified_sec INTEGER NOT NULL, bytes INTEGER NOT NULL, taken_ms INTEGER NOT NULL,
        screenshot INTEGER NOT NULL, text TEXT,
        dhash INTEGER, sharpness REAL, entropy REAL, faces INTEGER,
        measured_at INTEGER NOT NULL,
        PRIMARY KEY (phone, path),
        FOREIGN KEY (phone, path) REFERENCES files (phone, path) ON DELETE CASCADE
      ) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS sessions (
        id INTEGER PRIMARY KEY,
        phone TEXT NOT NULL, started INTEGER NOT NULL, finished INTEGER,
        items_removed INTEGER NOT NULL DEFAULT 0, bytes_freed INTEGER NOT NULL DEFAULT 0
      );
    ''');
  }

  int _now() => DateTime.now().millisecondsSinceEpoch;

  void rememberPhone(String serial, PhoneInfo info) {
    final now = _now();
    _db.execute('''
      INSERT INTO phones (serial, brand, model, android, first_seen, last_seen) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT (serial) DO UPDATE SET brand = excluded.brand, model = excluded.model,
        android = excluded.android, last_seen = excluded.last_seen
    ''', [serial, info.brand, info.model, info.androidVersion, now, now]);
  }

  /// Records the phone's current file list and reports what changed.
  /// Files that disappeared from the phone are forgotten, along with their
  /// measurements. Edited files keep their row but lose stale measurements
  /// (see [needingAnalysis]).
  InventoryDiff syncInventory(String phone, List<PhoneFile> files) {
    final now = _now();
    final known = <String, (int, int)>{
      for (final r in _db.select('SELECT path, modified_sec, bytes FROM files WHERE phone = ?', [phone]))
        r['path'] as String: (r['modified_sec'] as int, r['bytes'] as int),
    };

    var added = 0, changed = 0, unchanged = 0;
    final seen = <String>{};
    _transaction(() {
      final upsert = _db.prepare('''
        INSERT INTO files (phone, path, media_id, folder, bytes, mime, modified_sec, taken_ms, width, height,
                           duration_ms, first_seen, last_seen)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (phone, path) DO UPDATE SET media_id = excluded.media_id, folder = excluded.folder,
          bytes = excluded.bytes, mime = excluded.mime, modified_sec = excluded.modified_sec,
          taken_ms = excluded.taken_ms, width = excluded.width, height = excluded.height,
          duration_ms = excluded.duration_ms, last_seen = excluded.last_seen
      ''');
      try {
        for (final f in files) {
          if (!seen.add(f.path)) continue; // the phone listed the same path twice
          final before = known[f.path];
          if (before == null) {
            added++;
          } else if (before.$1 != f.modifiedSec || before.$2 != f.bytes) {
            changed++;
          } else {
            unchanged++;
          }
          upsert.execute([phone, f.path, f.id, f.folder, f.bytes, f.mime, f.modifiedSec, f.takenMs, f.width,
            f.height, f.durationMs, now, now]);
        }
      } finally {
        upsert.close();
      }
      final gone = known.keys.where((p) => !seen.contains(p)).toList();
      final delete = _db.prepare('DELETE FROM files WHERE phone = ? AND path = ?');
      try {
        for (final p in gone) {
          delete.execute([phone, p]);
        }
      } finally {
        delete.close();
      }
    });
    return InventoryDiff(added: added, changed: changed, removed: known.length - (changed + unchanged), unchanged: unchanged);
  }

  /// Files with no measurement, or whose measurement is out of date because
  /// the file changed since. Only these need to be copied and analysed.
  List<String> needingAnalysis(String phone) => [
        for (final r in _db.select('''
          SELECT f.path FROM files f
          LEFT JOIN measurements m ON m.phone = f.phone AND m.path = f.path
            AND m.modified_sec = f.modified_sec AND m.bytes = f.bytes
          WHERE f.phone = ? AND (m.path IS NULL
            -- Screenshots read before line positions were kept: read once more.
            OR (m.screenshot = 1 AND m.boxes IS NULL))
          ORDER BY f.path
        ''', [phone]))
          r['path'] as String,
      ];

  /// Saves what was measured, keyed by file path on the phone.
  void saveMeasurements(String phone, Map<String, Analysis> byPath) {
    final now = _now();
    _transaction(() {
      final put = _db.prepare('''
        INSERT OR REPLACE INTO measurements (phone, path, modified_sec, bytes, taken_ms, screenshot, text, boxes,
                                             dhash, sharpness, entropy, faces, landscape, measured_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''');
      try {
        for (final MapEntry(key: path, value: a) in byPath.entries) {
          put.execute([phone, path, a.modified, a.bytes, a.takenAtMs, a.screenshot ? 1 : 0, _seal(a.text), a.boxes,
            a.dHash, a.sharpness, a.entropy, a.faceCount, a.landscape == null ? null : (a.landscape! ? 1 : 0), now]);
        }
      } finally {
        put.close();
      }
    });
  }

  /// Remembered content fingerprints (path → MD5) for files that haven't
  /// changed since they were fingerprinted.
  Map<String, String> fingerprints(String phone) => {
        for (final r in _db.select('''
          SELECT p.path, p.md5 FROM fingerprints p
          JOIN files f ON f.phone = p.phone AND f.path = p.path
            AND f.modified_sec = p.modified_sec AND f.bytes = p.bytes
          WHERE p.phone = ?
        ''', [phone]))
          r['path'] as String: r['md5'] as String,
      };

  /// Remembers fingerprints just computed on the phone, tied to each file's
  /// current size and date (a changed file is fingerprinted again).
  void saveFingerprints(String phone, Map<String, String> md5ByPath) {
    _transaction(() {
      final put = _db.prepare('''
        INSERT OR REPLACE INTO fingerprints (phone, path, modified_sec, bytes, md5)
        SELECT phone, path, modified_sec, bytes, ? FROM files WHERE phone = ? AND path = ?
      ''');
      try {
        for (final MapEntry(key: path, value: md5) in md5ByPath.entries) {
          put.execute([md5, phone, path]);
        }
      } finally {
        put.close();
      }
    });
  }

  /// Up-to-date measurements for every file on the phone.
  Map<String, Analysis> measurements(String phone) => {
        for (final r in _db.select('''
          SELECT m.* FROM measurements m
          JOIN files f ON f.phone = m.phone AND f.path = m.path
            AND f.modified_sec = m.modified_sec AND f.bytes = m.bytes
          WHERE m.phone = ?
        ''', [phone]))
          r['path'] as String: Analysis(
            modified: r['modified_sec'] as int,
            bytes: r['bytes'] as int,
            takenAtMs: r['taken_ms'] as int,
            screenshot: r['screenshot'] == 1,
            text: _open(r['text'] as String?),
            boxes: r['boxes'] as String?,
            dHash: r['dhash'] as int?,
            sharpness: (r['sharpness'] as num?)?.toDouble(),
            entropy: (r['entropy'] as num?)?.toDouble(),
            faceCount: r['faces'] as int?,
            landscape: r['landscape'] == null ? null : r['landscape'] == 1,
          ),
      };

  int fileCount(String phone) =>
      _db.select('SELECT count(*) n FROM files WHERE phone = ?', [phone]).first['n'] as int;

  /// Starts a clean-up session; returns its id for [finishSession].
  int startSession(String phone) {
    _db.execute('INSERT INTO sessions (phone, started) VALUES (?, ?)', [phone, _now()]);
    return _db.lastInsertRowId;
  }

  void finishSession(int id, {required int itemsRemoved, required int bytesFreed}) {
    _db.execute('UPDATE sessions SET finished = ?, items_removed = ?, bytes_freed = ? WHERE id = ?',
        [_now(), itemsRemoved, bytesFreed, id]);
  }

  /// Total space freed on this phone across all finished sessions.
  int bytesFreed(String phone) =>
      _db.select('SELECT coalesce(sum(bytes_freed), 0) b FROM sessions WHERE phone = ? AND finished IS NOT NULL',
          [phone]).first['b'] as int;

  /// Writes the whole plan into the journal before anything is touched.
  /// Returns the op ids in the same order as [ops].
  List<int> planCleanOps(int session, String phone, List<PlannedOp> ops) {
    final ids = <int>[];
    final now = _now();
    _transaction(() {
      final put = _db.prepare('''
        INSERT INTO clean_ops (session, phone, path, media_id, bytes, method, backup, state, at)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'planned', ?)
      ''');
      try {
        for (final op in ops) {
          put.execute([session, phone, op.path, op.mediaId, op.bytes, op.method.name, op.backup, now]);
          ids.add(_db.lastInsertRowId);
        }
      } finally {
        put.close();
      }
    });
    return ids;
  }

  void markOp(int id, OpState state, {String? error}) {
    _db.execute('UPDATE clean_ops SET state = ?, error = ?, at = ? WHERE id = ?', [state.name, error, _now(), id]);
  }

  /// Ops of a session, in plan order.
  List<CleanOp> opsOf(int session) => [
        for (final r in _db.select('SELECT * FROM clean_ops WHERE session = ? ORDER BY id', [session])) CleanOp._(r),
      ];

  /// Ops left 'planned' by a clean-up that was interrupted (app closed,
  /// cable pulled). Checked on the next connection of that phone.
  List<CleanOp> unfinishedOps(String phone) => [
        for (final r in _db.select("SELECT * FROM clean_ops WHERE phone = ? AND state = 'planned' ORDER BY id", [phone]))
          CleanOp._(r),
      ];

  /// The phone a clean-up was made on, or null for an unknown session.
  String? phoneOf(int session) =>
      _db.select('SELECT phone FROM sessions WHERE id = ?', [session]).firstOrNull?['phone'] as String?;

  /// The most recent finished clean-up of a phone, for "Undo".
  int? lastSession(String phone) =>
      _db.select('SELECT id FROM sessions WHERE phone = ? AND finished IS NOT NULL ORDER BY id DESC LIMIT 1', [phone])
          .firstOrNull?['id'] as int?;

  void _transaction(void Function() body) {
    _db.execute('BEGIN');
    try {
      body();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void close() => _db.close();
}
