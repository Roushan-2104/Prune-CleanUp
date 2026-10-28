import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// This copy of Prune. Kept equal to pubspec.yaml's version (a test checks).
const appVersion = '1.0.1';

const _latestRelease = 'https://api.github.com/repos/Roushan-2104/Prune-CleanUp/releases/latest';
const releasesPage = 'https://github.com/Roushan-2104/Prune-CleanUp/releases/';

/// The app's one update check, started in main().
final updates = UpdateCheck();

/// The optional check for new versions: the only time Prune goes online.
///
/// Off until the user says yes (asked once, on Home). Then, at most once a
/// day, it asks GitHub which release is newest. The request carries no
/// information about the user or their phone: GitHub sees only that this
/// address asked. When a newer version exists, Home offers a link to its
/// page; installing it over this one keeps everything.
class UpdateCheck extends ChangeNotifier {
  UpdateCheck({File? settings, this.fetch = _fetchLatest, String? current})
      : _file = settings ?? File('${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}\\Prune\\settings.json'),
        current = current ??
            (kDebugMode ? (Platform.environment['PRUNE_FAKE_VERSION'] ?? appVersion) : appVersion);

  final File _file;
  final String current;

  /// Asks GitHub for the newest release: its version ("1.0.2") and page.
  final Future<({String version, String url})?> Function() fetch;

  /// Null until the user answers the one question.
  bool? allowed;

  /// A newer version than this one, and its page; null when up to date.
  String? newer, newerUrl;

  DateTime? _lastCheck;

  /// Reads the saved answer, and checks if allowed and a day has passed.
  Future<void> start() async {
    try {
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      allowed = j['updateCheck'] as bool?;
      _lastCheck = DateTime.tryParse('${j['lastCheck']}');
      _offer(j['latest'] as String?, j['latestUrl'] as String?);
    } catch (_) {
      // No settings yet: ask.
    }
    notifyListeners();
    if (allowed == true && (_lastCheck == null || DateTime.now().difference(_lastCheck!) > const Duration(days: 1))) {
      await check();
    }
  }

  /// The user's answer to "check for new versions?".
  Future<void> allow(bool yes) async {
    allowed = yes;
    if (!yes) newer = newerUrl = null;
    await _save();
    notifyListeners();
    if (yes) await check();
  }

  /// Asks GitHub now. Fails quietly: no network just means no news.
  Future<void> check() async {
    if (allowed != true) return;
    final latest = await fetch().catchError((_) => null);
    _lastCheck = DateTime.now();
    if (latest != null) _offer(latest.version, latest.url);
    await _save(latest: latest);
    notifyListeners();
  }

  void _offer(String? version, String? url) {
    final ok = version != null && url != null && url.startsWith(releasesPage) && isNewer(version, current);
    newer = ok ? version : null;
    newerUrl = ok ? url : null;
  }

  Future<void> _save({({String version, String url})? latest}) async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode({
        'updateCheck': allowed,
        if (_lastCheck != null) 'lastCheck': _lastCheck!.toIso8601String(),
        if ((latest?.version ?? newer) != null) 'latest': latest?.version ?? newer,
        if ((latest?.url ?? newerUrl) != null) 'latestUrl': latest?.url ?? newerUrl,
      }));
    } catch (_) {
      // Can't save: it simply asks again next time.
    }
  }
}

/// Whether version [a] ("1.0.2", "v1.10.0") is newer than [b]. Anything
/// unreadable is never newer.
bool isNewer(String a, String b) {
  List<int>? parts(String v) {
    final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(v.trim());
    return m == null ? null : [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
  }

  final x = parts(a), y = parts(b);
  if (x == null || y == null) return false;
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i] > y[i];
  }
  return false;
}

/// One HTTPS request to GitHub's public API; nothing about the user is sent.
Future<({String version, String url})?> _fetchLatest() async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = 'Prune-update-check';
  try {
    final req = await client.getUrl(Uri.parse(_latestRelease));
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
    if (body.length > 200000) return null;
    final j = jsonDecode(body) as Map<String, dynamic>;
    final tag = j['tag_name'], url = j['html_url'];
    if (tag is! String || url is! String) return null;
    return (version: tag.replaceFirst(RegExp('^v'), ''), url: url);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
