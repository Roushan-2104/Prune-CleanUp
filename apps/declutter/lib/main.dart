import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:declutter_store/declutter_store.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'home_page.dart';
import 'phone_session.dart';
import 'photo_scan.dart';
import 'previews.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized(); // in-app video and audio playback
  PreviewCache.clearAll(); // previews and photo copies never outlive a session…
  PhotoScan.clearWork();
  clearStaleTempCopies(Directory.systemTemp); // left by a crash or power cut
  runApp(PruneApp(session: PhoneSession(Store.open(databasePath()))));
  // …and are deleted again when the window is closed.
  _exitListener = AppLifecycleListener(
    onExitRequested: () async {
      PreviewCache.clearAll();
      PhotoScan.clearWork();
      return AppExitResponse.exit;
    },
  );
}

/// Folders of private photo copies that phone_link and the vision helper
/// make in %TEMP% and normally delete as soon as they are done.
const staleTempPrefixes = ['declutter_copy_', 'declutter_vision_', 'prune_vision_'];

/// Deletes folders in [temp] named like [staleTempPrefixes]: copies a crash
/// or power cut left behind. Nothing else in [temp] is touched.
void clearStaleTempCopies(Directory temp) {
  try {
    for (final entry in temp.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = entry.path.substring(entry.path.lastIndexOf(Platform.pathSeparator) + 1);
      if (!staleTempPrefixes.any(name.startsWith)) continue;
      try {
        entry.deleteSync(recursive: true);
      } catch (_) {
        // Still in use: it goes next time.
      }
    }
  } catch (_) {
    // %TEMP% unreadable: nothing to clear.
  }
}

// Kept so the listener lives as long as the app.
// ignore: unused_element
AppLifecycleListener? _exitListener;

/// %LOCALAPPDATA%\Prune\prune.db — the laptop's memory of each phone.
///
/// Local, not Roaming: on work and school PCs Roaming AppData is copied to a
/// server at sign-out, and this file describes what's on a personal phone.
/// A database from before the app was called Prune (Local or Roaming
/// "Declutter" folder) is moved here once.
String databasePath() {
  final local = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
  final dir = Directory('$local\\Prune')..createSync(recursive: true);
  final path = '${dir.path}\\prune.db';
  if (!File(path).existsSync()) {
    for (final oldDir in [
      '$local\\Declutter',
      if (Platform.environment['APPDATA'] case final roaming?) '$roaming\\Declutter',
    ]) {
      final old = '$oldDir\\declutter.db';
      if (!File(old).existsSync()) continue;
      try {
        for (final suffix in ['', '-wal', '-shm']) {
          if (File('$old$suffix').existsSync()) File('$old$suffix').renameSync('$path$suffix');
        }
        // Whatever else is there is temporary (previews, photo copies).
        Directory(oldDir).deleteSync(recursive: true);
      } on FileSystemException {
        // Different drive or in use: start fresh; the old one is left as it was.
      }
      break;
    }
  }
  return path;
}

class PruneApp extends StatelessWidget {
  const PruneApp({super.key, required this.session});
  final PhoneSession session;

  @override
  Widget build(BuildContext context) {
    // Light on purpose: photos and small screenshot text are judged most
    // faithfully on a paper ground. See theme.dart.
    return MaterialApp(
      title: 'Prune',
      debugShowCheckedModeBanner: false,
      theme: pruneTheme(),
      home: HomePage(session: session),
    );
  }
}
