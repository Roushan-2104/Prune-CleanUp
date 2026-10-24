import 'dart:io';

import 'package:declutter_store/declutter_store.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'home_page.dart';
import 'phone_session.dart';
import 'previews.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized(); // in-app video and audio playback
  PreviewCache.clearAll(); // previews never outlive a session
  runApp(DeclutterApp(session: PhoneSession(Store.open(databasePath()))));
}

/// %APPDATA%\Declutter\declutter.db — the laptop's memory of each phone.
String databasePath() {
  final base = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
  final dir = Directory('$base\\Declutter')..createSync(recursive: true);
  return '${dir.path}\\declutter.db';
}

class DeclutterApp extends StatelessWidget {
  const DeclutterApp({super.key, required this.session});
  final PhoneSession session;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0B6E78);
    return MaterialApp(
      title: 'Declutter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: HomePage(session: session),
    );
  }
}
