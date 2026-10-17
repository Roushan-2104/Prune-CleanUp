import 'package:flutter/material.dart';

import 'app_state.dart';
import 'ui/home_screen.dart';

void main() {
  final state = AppState()..openApp();
  runApp(SaafApp(state: state));
}

class SaafApp extends StatelessWidget {
  const SaafApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Saaf',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark, useMaterial3: true),
      home: HomeScreen(state: state),
    );
  }
}
