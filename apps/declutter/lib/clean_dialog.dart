import 'package:declutter_store/declutter_store.dart' show CleanMethod, CleanOp, OpState, Store;
import 'package:flutter/material.dart';
import 'package:phone_link/phone_link.dart';

import 'cleaning.dart';
import 'friendly_error.dart';
import 'phone_session.dart';

/// Confirm → progress → summary (with Undo). Nothing changes on the phone
/// until the user presses the final button.
Future<void> showCleanDialog(BuildContext context, PhoneSession session, List<PhoneFile> items) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CleanDialog(session: session, plan: CleanPlan(items)),
  );
}

enum _Stage { confirm, running, done, undoing, undone }

class _CleanDialog extends StatefulWidget {
  const _CleanDialog({required this.session, required this.plan});
  final PhoneSession session;
  final CleanPlan plan;

  @override
  State<_CleanDialog> createState() => _CleanDialogState();
}

class _CleanDialogState extends State<_CleanDialog> {
  var stage = _Stage.confirm;
  var backup = true;
  var understood = false;
  var step = '';
  var progress = 0.0;
  var cancelling = false;
  CleanResult? result;
  int restored = 0;
  int kept = 0;
  String? error;

  // The phone this dialog was opened for — fixed, even if the app re-reads
  // or switches phones meanwhile.
  late final String? serial = widget.session.serial;

  // Real phones are allowed here, and only here: this runner acts only
  // after the user presses Clean below. Everything else stays read-only.
  late final runner = CleanRunner(
    store: widget.session.store,
    adb: widget.session.adb,
    serial: serial!,
    phoneLabel: '${widget.session.info?.model ?? 'phone'}-$serial',
    allowRealPhone: true,
  );

  bool get canStart => serial != null && (backup || widget.plan.toDelete.isEmpty || understood);

  Future<void> _run() async {
    setState(() => stage = _Stage.running);
    try {
      result = await runner.run(widget.plan, backup: backup,
          onProgress: (s, p) => setState(() {
                step = s;
                progress = p;
              }));
      // Cut off midway (cable pulled): what was done is recorded and can
      // still be undone once the phone is back.
      if (result!.stoppedBy case final e?) error = friendlyError(e);
    } catch (e) {
      error = friendlyError(e);
    }
    setState(() => stage = _Stage.done);
    widget.session.rescan();
  }

  void _cancel() {
    runner.cancel();
    setState(() {
      cancelling = true;
      step = 'Stopping after this item…';
    });
  }

  Future<void> _undo() async {
    setState(() {
      stage = _Stage.undoing;
      error = null;
      kept = 0;
    });
    // Counted from the journal, so items put back before a pulled cable
    // still count when Undo is pressed again.
    int putBack() => widget.session.store.opsOf(result!.session!).where((o) => o.state == OpState.restored).length;
    try {
      await runner.undo(result!.session!,
          onProgress: (s) => setState(() => step = s), onSkipped: (_, _) => kept++);
    } on PhoneDisconnected catch (e) {
      // Nothing is lost: plug the phone back in and press Undo again.
      setState(() {
        restored = putBack();
        error = friendlyError(e);
        stage = _Stage.done;
      });
      return;
    } catch (e) {
      error = friendlyError(e);
    }
    setState(() {
      restored = putBack();
      stage = _Stage.undone;
    });
    widget.session.rescan();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.plan, t = Theme.of(context).textTheme, c = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(switch (stage) {
        _Stage.confirm => 'Clean ${p.toTrash.length + p.toDelete.length} items · ${formatBytes(p.bytes)}?',
        _Stage.running => cancelling ? 'Cancelling…' : 'Cleaning…',
        _Stage.done => result?.cancelled == true ? 'Cancelled' : (error == null ? 'Done' : 'Stopped'),
        _Stage.undoing => 'Putting things back…',
        _Stage.undone => 'Undone',
      }),
      content: SizedBox(
        width: 520,
        child: switch (stage) {
          _Stage.confirm => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (p.toTrash.isNotEmpty)
                _Line(Icons.delete_outline, '${p.toTrash.length} items go to the phone\'s Trash',
                    'You can restore them on the phone for 30 days, or with Undo here.'),
              if (p.toDelete.isNotEmpty)
                _Line(Icons.warning_amber_outlined, '${p.toDelete.length} hidden items (${formatBytes(p.deleteBytes)}) are deleted outright',
                    'Android has no Trash for files it hides, like WhatsApp sent copies.'),
              if (p.toDelete.isNotEmpty) ...[
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: backup,
                  onChanged: (v) => setState(() => backup = v!),
                  title: const Text('Back up to this laptop first (recommended)'),
                  subtitle: const Text('Saved in your user folder under "Prune Backups". Undo copies them back.'),
                ),
                if (!backup)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: understood,
                    onChanged: (v) => setState(() => understood = v!),
                    title: Text('I understand these ${p.toDelete.length} items can\'t be recovered',
                        style: TextStyle(color: c.error)),
                  ),
              ],
              const SizedBox(height: 8),
              Text('Nothing on the phone changes until you press Clean.', style: t.bodySmall),
            ]),
          _Stage.running || _Stage.undoing => Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: stage == _Stage.running && progress >= 0 ? progress : null),
              const SizedBox(height: 12),
              Text(step),
              const SizedBox(height: 8),
              Text(
                  stage == _Stage.running && !cancelling
                      ? 'Cancel stops after the current item and puts back everything cleaned so far.'
                      : 'Every step is recorded. If the cable comes out, Undo still works.',
                  style: t.bodySmall),
            ]),
          _Stage.done when result?.cancelled == true =>
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  result!.session == null
                      ? 'Nothing on the phone was changed'
                      : result!.done == 0
                          ? 'Everything is back where it was${result!.putBack > 0 ? ': put back ${_items(result!.putBack)}' : ''}'
                          : 'Put back ${_items(result!.putBack)}. ${_items(result!.done)} could not be: '
                              '${result!.failed.values.first}',
                  style: t.titleMedium),
              if (error != null) Text(error!, style: TextStyle(color: c.error)),
            ]),
          _Stage.done => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (result != null) ...[
                Text('Freed ${formatBytes(result!.bytesFreed)} · ${result!.done} items removed', style: t.titleMedium),
                if (result!.failed.isNotEmpty)
                  Text('${result!.failed.length} items were left in place: ${result!.failed.values.first}'),
              ],
              if (error != null) Text(error!, style: TextStyle(color: c.error)),
            ]),
          _Stage.undone => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Put back $restored of ${result?.done ?? 0} items.'),
              if (kept > 0) Text(keptLine(kept)),
              if (error != null) Text(error!, style: TextStyle(color: c.error)),
            ]),
        },
      ),
      actions: switch (stage) {
        _Stage.confirm => [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: canStart ? _run : null, child: Text('Clean ${formatBytes(p.bytes)}')),
          ],
        _Stage.running => [TextButton(onPressed: cancelling ? null : _cancel, child: Text(cancelling ? 'Cancelling…' : 'Cancel'))],
        _Stage.undoing => const [],
        _Stage.done => [
            if (result != null && result!.done > 0) TextButton(onPressed: _undo, child: const Text('Undo')),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        _Stage.undone => [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      },
    );
  }
}

/// What Undo can still put back from a phone's last clean-up: items that
/// went to the phone's Trash, and deleted items that have a laptop backup.
/// Null when there is nothing left to put back.
///
/// Items an earlier Undo kept because a newer file is in their place
/// ([keptNewerFile]) are left out: offering them again would only end the
/// same way.
class UndoableCleanUp {
  UndoableCleanUp._(this.session, this.phone, this.fromTrash, this.fromBackup);

  /// Looks up the last finished clean-up of the phone with [serial].
  static UndoableCleanUp? of(Store store, String serial) {
    final session = store.lastSession(serial);
    if (session == null) return null;
    final ops = store.opsOf(session).where((o) => o.state == OpState.done && o.error != keptNewerFile).toList();
    bool trash(CleanOp o) => o.method == CleanMethod.trash;
    final u = UndoableCleanUp._(
      session,
      serial,
      ops.where(trash).length,
      ops.where((o) => !trash(o) && o.backup != null).length,
    );
    return u.count == 0 ? null : u;
  }

  final int session;

  /// The phone the clean-up was made on. Undo puts things back on this
  /// phone only.
  final String phone;

  /// Items that come back out of the phone's Trash.
  final int fromTrash;

  /// Deleted items that are copied back from this laptop.
  final int fromBackup;

  int get count => fromTrash + fromBackup;
}

/// "Undo last clean-up" from the home screen: confirm → put back → summary.
/// Works for the phone that is connected now, so Undo is still there after
/// the clean-up dialog was closed or the cable came out.
Future<void> showUndoDialog(BuildContext context, PhoneSession session, UndoableCleanUp undo) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UndoDialog(session: session, undo: undo),
  );
}

enum _UndoStage { confirm, undoing, done }

class _UndoDialog extends StatefulWidget {
  const _UndoDialog({required this.session, required this.undo});
  final PhoneSession session;
  final UndoableCleanUp undo;

  @override
  State<_UndoDialog> createState() => _UndoDialogState();
}

class _UndoDialogState extends State<_UndoDialog> {
  var stage = _UndoStage.confirm;
  var step = '';
  int restored = 0;
  int kept = 0;
  String? error;

  /// The phone the clean-up was made on, fixed when the dialog opened: if
  /// the app switches phones meanwhile, Put back refuses instead of acting
  /// on the other phone.
  String get serial => widget.undo.phone;

  /// Only the phone the clean-up was made on, and only while it's here.
  bool get samePhone => widget.session.serial == serial && widget.session.state == LinkState.ready;

  Future<void> _undo() async {
    if (!samePhone) {
      setState(() {
        error = 'The phone isn\'t connected. Plug it back in and unlock it, then try again.';
        stage = _UndoStage.done;
      });
      return;
    }
    setState(() {
      stage = _UndoStage.undoing;
      error = null;
      kept = 0;
    });
    final store = widget.session.store, id = widget.undo.session;
    // Counted from the journal, so it is right even after a pulled cable;
    // items an earlier Undo put back are not counted again.
    int putBack() => store.opsOf(id).where((o) => o.state == OpState.restored).length;
    final before = putBack();
    // Put back only on user request, for this phone's own clean-up; the
    // same rule as Undo in the clean-up dialog.
    final runner = CleanRunner(
      store: store,
      adb: widget.session.adb,
      serial: serial,
      phoneLabel: '${widget.session.info?.model ?? 'phone'}-$serial',
      allowRealPhone: true,
    );
    try {
      await runner.undo(id, onProgress: (s) => setState(() => step = s), onSkipped: (_, _) => kept++);
    } catch (e) {
      // A pulled cable loses nothing: what came back is in the journal, and
      // the rest can be put back once the phone is here again.
      error = friendlyError(e);
    }
    if (!mounted) return;
    setState(() {
      restored = putBack() - before;
      stage = _UndoStage.done;
    });
    widget.session.rescan();
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.undo, t = Theme.of(context).textTheme, c = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(switch (stage) {
        _UndoStage.confirm => 'Undo last clean-up?',
        _UndoStage.undoing => 'Putting things back…',
        _UndoStage.done => error == null ? 'Undone' : 'Stopped',
      }),
      content: SizedBox(
        width: 520,
        child: switch (stage) {
          _UndoStage.confirm => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(undoSummary(u), style: t.titleMedium),
              const SizedBox(height: 4),
              if (u.fromTrash > 0)
                _Line(Icons.restore_from_trash_outlined, '${u.fromTrash} come out of the phone\'s Trash',
                    'Anything left in the Trash for more than 30 days may already be gone.'),
              if (u.fromBackup > 0)
                _Line(Icons.laptop_outlined, '${u.fromBackup} are copied back from this laptop',
                    'From the backup in "Prune Backups"'),
              const SizedBox(height: 8),
              Text('Nothing on the phone changes until you press Put back', style: t.bodySmall),
            ]),
          _UndoStage.undoing => Column(mainAxisSize: MainAxisSize.min, children: [
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Text(step),
              const SizedBox(height: 8),
              Text('Every step is recorded. If the cable comes out, you can carry on later.', style: t.bodySmall),
            ]),
          _UndoStage.done => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (restored > 0 || error == null) Text('Put back $restored of ${u.count} items.'),
              if (kept > 0) Text(keptLine(kept)),
              if (error != null) Text(error!, style: TextStyle(color: c.error)),
            ]),
        },
      ),
      actions: switch (stage) {
        _UndoStage.confirm => [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: _undo, child: Text('Put back ${_items(u.count)}')),
          ],
        _UndoStage.undoing => const [],
        _UndoStage.done => [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      },
    );
  }
}

/// "Put back 12 items from your last clean-up." (one line, for the home
/// screen and the confirm step alike).
String undoSummary(UndoableCleanUp u) => 'Put back ${_items(u.count)} from your last clean-up.';

/// Why some items stayed where they were after Undo.
String keptLine(int n) =>
    '${n == 1 ? '1 was' : '$n were'} not put back: a newer file is in its place. The backup is still on this laptop.';

String _items(int n) => n == 1 ? '1 item' : '$n items';

class _Line extends StatelessWidget {
  const _Line(this.icon, this.title, this.detail);
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(detail),
      );
}
