import 'package:declutter_store/declutter_store.dart' show OpState;
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
  CleanResult? result;
  int restored = 0;
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

  Future<void> _undo() async {
    setState(() {
      stage = _Stage.undoing;
      error = null;
    });
    // Counted from the journal, so items put back before a pulled cable
    // still count when Undo is pressed again.
    int putBack() => widget.session.store.opsOf(result!.session).where((o) => o.state == OpState.restored).length;
    try {
      await runner.undo(result!.session, onProgress: (s) => setState(() => step = s));
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
        _Stage.running => 'Cleaning…',
        _Stage.done => error == null ? 'Done' : 'Stopped',
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
              LinearProgressIndicator(value: stage == _Stage.running ? progress : null),
              const SizedBox(height: 12),
              Text(step),
              const SizedBox(height: 8),
              Text('Every step is recorded. If the cable comes out, Undo still works.', style: t.bodySmall),
            ]),
          _Stage.done => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (result != null) ...[
                Text('Freed ${formatBytes(result!.bytesFreed)} · ${result!.done} items removed', style: t.titleMedium),
                if (result!.failed.isNotEmpty)
                  Text('${result!.failed.length} items were left in place: ${result!.failed.values.first}'),
              ],
              if (error != null) Text(error!, style: TextStyle(color: c.error)),
            ]),
          _Stage.undone => Text('Put back $restored of ${result?.done ?? 0} items.${error != null ? '\n$error' : ''}'),
        },
      ),
      actions: switch (stage) {
        _Stage.confirm => [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: canStart ? _run : null, child: Text('Clean ${formatBytes(p.bytes)}')),
          ],
        _Stage.running || _Stage.undoing => const [],
        _Stage.done => [
            if (result != null && result!.done > 0) TextButton(onPressed: _undo, child: const Text('Undo')),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        _Stage.undone => [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      },
    );
  }
}

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
