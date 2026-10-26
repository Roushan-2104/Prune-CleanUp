/// Thrown when code tries to run a phone command that could change the phone.
class NotReadOnlyError extends Error {
  NotReadOnlyError(this.command);
  final String command;

  @override
  String toString() => 'Blocked: "$command" is not a read-only phone command.';
}

// The only shell commands Prune may run on a phone while it is
// inspecting it — every one of them only *reads* (see ensureReadOnly):
//   getprop, df, du, stat, ls        facts about the phone and its files
//   content query                     Android's media list
//   dumpsys diskstats                 storage use
//   pm list packages -3               names of apps the user installed
//   cat                               a file's bytes, to the laptop
//   md5sum                            a content fingerprint
//   find                              only with the options in _findOptions
//   dd                                only the read-a-slice form in _ddRead
// Changing the phone is a separate, user-approved step (PhoneCleaner) that
// never goes through this path.

/// The only `dd` allowed: read [count] blocks of [bs] bytes from a quoted
/// file, starting [skip] blocks in, to the laptop. No output file, no flags.
final _ddRead = RegExp(r"^dd if='(?:[^']|'\\'')*' bs=\d+ skip=\d+ count=\d+ status=none$");

/// The same slice read, encoded as plain text on the phone (base64, one
/// line). The only pipe ever allowed: Windows' adb alters raw bytes over a
/// long-lived connection, but can't alter letters and digits.
final _ddReadBase64 =
    RegExp(r"^dd if='(?:[^']|'\\'')*' bs=\d+ skip=\d+ count=\d+ status=none \| base64 -w 0(?:; echo)?$");

/// `find` can also delete or run other commands (-delete, -exec, …), so only
/// these listing options are accepted. Anything else is blocked.
const _findOptions = {
  '-type', '-printf', '-maxdepth', '-mindepth', '-name', '-iname', '-path', '-prune', '-o', '-not', '-size',
  '-mtime', '-xdev', '(', ')', '!',
};

/// Characters that could chain or redirect a second command (e.g. "ls; rm x",
/// "cat a > b"). Paths are always quoted by [shellQuote], so legitimate use
/// never needs these outside quotes.
final _dangerous = RegExp(r'[;&|`$<>\n]');

/// Commands that must match exactly, word for word.
const _exact = {'dumpsys diskstats', 'pm list packages -3'};

/// Throws [NotReadOnlyError] unless [command] is on the read-only list and
/// contains no way to sneak in a second command.
///
/// The command is read the way the phone's shell will read it, into words.
/// Anything this reader can't be certain about — double quotes, a stray
/// backslash, an unclosed quote — is refused rather than guessed at.
void ensureReadOnly(String command) {
  final trimmed = command.trim();
  if (_ddReadBase64.hasMatch(trimmed)) return;
  final words = _shellWords(trimmed);
  if (words == null || words.isEmpty) throw NotReadOnlyError(command);

  final head = words.first;
  final ok = switch (head) {
    'getprop' || 'df' || 'du' || 'stat' || 'ls' || 'cat' || 'md5sum' => true,
    'content' => words.length > 1 && words[1] == 'query',
    'dumpsys' || 'pm' => _exact.contains(words.join(' ')),
    'dd' => _ddRead.hasMatch(trimmed),
    // A word starting with '-' is an option to find even when quoted
    // ('-delete' deletes), so options are checked after unquoting.
    'find' => words.skip(1).where((w) => w.startsWith('-') || w == '(' || w == ')' || w == '!').every(_findOptions.contains),
    _ => false,
  };
  if (!ok) throw NotReadOnlyError(command);
}

/// Wraps [s] in single quotes for the phone's shell, so spaces and symbols in
/// file names are treated as plain text.
String shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// Splits [s] into shell words, or returns null when it contains anything
/// beyond plain words and single quotes (plus `\'`, which [shellQuote] uses):
/// operators that chain or redirect (; & | ` $ < > newline), double quotes,
/// other backslashes, or an unclosed quote.
List<String>? _shellWords(String s) {
  final words = <String>[];
  final word = StringBuffer();
  var inWord = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == "'") {
      final end = s.indexOf("'", i + 1);
      if (end < 0) return null; // unclosed
      word.write(s.substring(i + 1, end));
      inWord = true;
      i = end;
    } else if (c == r'\') {
      if (i + 1 >= s.length || s[i + 1] != "'") return null;
      word.write("'");
      inWord = true;
      i++;
    } else if (c == ' ' || c == '\t') {
      if (inWord) words.add(word.toString());
      word.clear();
      inWord = false;
    } else if (_dangerous.hasMatch(c) || c == '"' || c == '\r') {
      return null;
    } else {
      word.write(c);
      inWord = true;
    }
  }
  if (inWord) words.add(word.toString());
  return words;
}
