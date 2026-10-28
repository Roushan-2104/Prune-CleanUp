import 'dart:io';

/// Where feedback goes: the project's public issue forms on GitHub.
/// This only opens the user's browser; Prune itself sends nothing.
const feedbackUrl = 'https://github.com/Roushan-2104/Prune-CleanUp/issues/new/choose';
const accuracyFeedbackUrl = 'https://github.com/Roushan-2104/Prune-CleanUp/issues/new?template=2-accuracy.yml';

/// Opens [url] in the default browser. Only fixed https addresses of the
/// project are ever passed here, never anything read from a phone.
Future<void> openInBrowser(String url) async {
  if (!url.startsWith('https://github.com/Roushan-2104/Prune-CleanUp/')) return;
  final explorer = '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\explorer.exe';
  await Process.run(explorer, [url]);
}
