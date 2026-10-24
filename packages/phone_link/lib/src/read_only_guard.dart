/// Thrown when code tries to run a phone command that could change the phone.
class NotReadOnlyError extends Error {
  NotReadOnlyError(this.command);
  final String command;

  @override
  String toString() => 'Blocked: "$command" is not a read-only phone command.';
}

/// The only shell commands Declutter may run on a phone while it is
/// inspecting it. Every one of them only *reads*.
///
/// Deleting will come later as a separate, explicit, user-approved step —
/// it will never go through this path.
const _allowed = <String>[
  'getprop ',
  'df ',
  'du ',
  'stat ',
  'ls ',
  'content query ',
  'dumpsys diskstats',
  'cat ', // used to stream a file's bytes *to* the laptop
  'find ', // only with the options in _findOptions
  'md5sum ', // fingerprints a file's content; prints a hash, changes nothing
];

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

/// Throws [NotReadOnlyError] unless [command] is on the read-only list and
/// contains no way to sneak in a second command.
void ensureReadOnly(String command) {
  final trimmed = command.trimLeft();
  if (!_allowed.any((a) => trimmed == a.trim() || trimmed.startsWith(a))) {
    throw NotReadOnlyError(command);
  }
  final unquoted = _withoutQuotedParts(trimmed);
  if (_dangerous.hasMatch(unquoted)) {
    throw NotReadOnlyError(command);
  }
  if (trimmed.startsWith('find ')) {
    final options = unquoted.split(RegExp(r'\s+')).where((t) => t.startsWith('-') || t == '(' || t == ')' || t == '!');
    if (options.any((o) => !_findOptions.contains(o))) throw NotReadOnlyError(command);
  }
}

/// Wraps [s] in single quotes for the phone's shell, so spaces and symbols in
/// file names are treated as plain text.
String shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// Removes single-quoted sections so their contents aren't mistaken for
/// shell operators.
String _withoutQuotedParts(String s) => s.replaceAll(RegExp(r"'(?:[^']|'\\'')*'"), "''");
