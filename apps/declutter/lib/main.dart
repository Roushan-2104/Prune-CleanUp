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
  runApp(DeclutterApp(session: PhoneSession(Store.open(databasePath()))));
  // …and are deleted again when the window is closed.
  _exitListener = AppLifecycleListener(
    onExitRequested: () async {
      PreviewCache.clearAll();
      PhotoScan.clearWork();
      return AppExitResponse.exit;
    },
  );
}

// Kept so the listener lives as long as the app.
// ignore: unused_element
AppLifecycleListener? _exitListener;

/// %LOCALAPPDATA%\Declutter\declutter.db — the laptop's memory of each phone.
///
/// Local, not Roaming: on work and school PCs Roaming AppData is copied to a
/// server at sign-out, and this file describes what's on a personal phone.
/// A database left in the old Roaming place is moved here once.
String databasePath() {
  final local = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
  final dir = Directory('$local\\Declutter')..createSync(recursive: true);
  final path = '${dir.path}\\declutter.db';
  final roaming = Platform.environment['APPDATA'];
  if (roaming != null && !File(path).existsSync()) {
    final old = '$roaming\\Declutter\\declutter.db';
    try {
      for (final suffix in ['', '-wal', '-shm']) {
        if (File('$old$suffix').existsSync()) File('$old$suffix').renameSync('$path$suffix');
      }
      final oldDir = Directory('$roaming\\Declutter');
      if (oldDir.existsSync() && oldDir.listSync().isEmpty) oldDir.deleteSync();
    } on FileSystemException {
      // Different drive or in use: start fresh here; the old one is left as it was.
    }
  }
  return path;
}

class DeclutterApp extends StatelessWidget {
  const DeclutterApp({super.key, required this.session});
  final PhoneSession session;

  @override
  Widget build(BuildContext context) {
    // Light on purpose: photos and small screenshot text are judged most
    // faithfully on a paper ground. See theme.dart.
    return MaterialApp(
      title: 'Declutter',
      debugShowCheckedModeBanner: false,
      theme: declutterTheme(),
      home: HomePage(session: session),
    );
  }
}
