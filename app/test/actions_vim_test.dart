// Vim controller tests: modes, counts, key sequences, the : command line, . repeat, recording and replay.
import 'package:caw/actions/actions.dart';
import 'package:caw/actions/keymap.dart';
import 'package:caw/actions/keys.dart';
import 'package:caw/actions/macro.dart';
import 'package:caw/actions/vim.dart';
import 'package:flutter_test/flutter_test.dart';

class Rig {
  final calls = <String>[];
  late final VimController vim;

  Rig({Area area = Area.pattern}) {
    final reg = ActionRegistry.standard();
    vim = VimController(
      registry: reg,
      keymap: Keymap.defaults(reg),
      handler: (id, {int count = 1, String? arg}) => calls.add('$id*$count${arg == null ? '' : ' $arg'}'),
    )..area = area;
  }

  KeyResult key(String chord) => vim.handleKey(KeyChord.parse(chord));

  /// Presses each space-separated chord in turn; returns the last result.
  KeyResult keys(String seq) {
    late KeyResult r;
    for (final c in seq.split(' ')) {
      r = key(c);
    }
    return r;
  }

  KeyResult type(String text) {
    late KeyResult r;
    for (final ch in text.split('')) {
      final upper = ch.toUpperCase() != ch.toLowerCase() && ch == ch.toUpperCase();
      r = vim.handleKey(ch == ' ' ? const KeyChord('Space') : KeyChord(ch.toUpperCase(), shift: upper));
    }
    return r;
  }
}

void main() {
  test('a key runs its action in the current area', () {
    final r = Rig();
    expect(r.key('W').handled, isTrue);
    r.vim.area = Area.arranger;
    r.key('W');
    r.key('Space');
    expect(r.calls, ['roll.notes.up*1', 'arranger.layer.prev*1', 'transport.playstop*1']);
    expect(r.key('Alt+9').handled, isFalse);
  });

  test('counts: 3E copies after with count 3, 12W, and 0 only after a digit', () {
    final r = Rig();
    final res = r.keys('3 E');
    expect(r.calls, ['roll.select.copyafter*3']);
    expect(res.toast, 'Copy after ×3');
    r.keys('1 2 W');
    expect(r.calls.last, 'roll.notes.up*12');
    r.keys('1 0 S');
    expect(r.calls.last, 'roll.notes.down*10');
    expect(r.key('0').handled, isFalse);
    r.vim.area = Area.arranger;
    r.keys('4 ]');
    expect(r.calls.last, 'arranger.layer.longer*4');
  });

  test('multi-key sequences show hints and run on the last key', () {
    final r = Rig(area: Area.code);
    final h = r.key('C');
    expect(h.handled, isTrue);
    expect(h.hints.map((e) => e.keys), containsAll(['W', 'I W']));
    expect(r.vim.pendingKeys, 'C');
    r.keys('I W');
    expect(r.calls, ['code.vim.changeInnerWord*1']);
    expect(r.vim.mode, VimMode.insert);
    r.key('Esc');
    r.keys('2 X X');
    expect(r.calls.last, 'code.vim.deleteLine*2');
    final dead = r.keys('Y Q');
    expect(dead.error, isTrue);
    expect(r.vim.pendingKeys, '');
  });

  test(': runs commands with values', () {
    final r = Rig();
    r.key(':');
    expect(r.vim.commandLineOpen, isTrue);
    r.type('bp');
    expect(r.vim.completions.first.keys, 'bpm');
    r.type('m 140');
    final res = r.key('Enter');
    expect(r.calls, ['transport.bpm*1 140']);
    expect(res.toast, 'Set tempo 140');
    expect(r.vim.commandLineOpen, isFalse);

    for (final cmd in ['grid 1/16', 'quantize', 'export loop', 'live 400ms', 'swap bar', 'key A minor']) {
      r.vim.openCommandLine();
      r.vim.setCommandText(cmd);
      r.vim.submitCommand();
    }
    expect(r.calls.sublist(1), [
      'roll.grid.set*1 1/16',
      'roll.notes.quantize*1',
      'export.now*1 loop',
      'builder.live.delay*1 400ms',
      'builder.swapTiming*1 bar',
      'roll.key.set*1 A minor',
    ]);
    r.vim.openCommandLine();
    r.vim.setCommandText('quantize hard');
    expect(r.vim.submitCommand().error, isTrue);
    r.vim.openCommandLine();
    r.vim.setCommandText('frobnicate');
    expect(r.vim.submitCommand().toast, 'Not a command: frobnicate');
    r.key(':');
    r.key('Esc');
    expect(r.vim.commandLineOpen, isFalse);
  });

  test('/ searches with the typed text in the code editor', () {
    final r = Rig(area: Area.code);
    r.key('/');
    expect(r.vim.prompt, '/');
    r.type('saw');
    r.key('Enter');
    expect(r.calls, ['code.vim.search*1 saw']);
  });

  test('. repeats the last change with its count, or a new one', () {
    final r = Rig();
    expect(r.key('.').error, isTrue);
    r.keys('3 E');
    r.key('Ctrl+W'); // movement is not a change
    r.key('.');
    expect(r.calls, ['roll.select.copyafter*3', 'roll.cursor.up*1', 'roll.select.copyafter*3']);
    r.keys('5 .');
    expect(r.calls.last, 'roll.select.copyafter*5');
  });

  test('Alt+Q records into a slot, @ replays with counts, and it is an ordinary macro', () {
    final r = Rig();
    Macro? saved;
    r.vim.onMacroRecorded = (m) => saved = m;
    r.key('Alt+Q');
    expect(r.vim.awaitingSlot, isTrue);
    r.key('A');
    expect(r.vim.recording, isTrue);
    expect(r.vim.recordingSlot, 'a');
    r.keys('2 E W');
    r.vim.runAction('transport.bpm', arg: '120');
    r.key('Alt+Q');
    expect(r.vim.recording, isFalse);
    expect(saved!.steps, const [
      MacroStep(ActionRef.action('roll.select.copyafter'), repeat: 2),
      MacroStep(ActionRef.action('roll.notes.up')),
      MacroStep(ActionRef.action('transport.bpm'), arg: '120'),
    ]);
    expect(r.vim.keymap.macros['a'], saved);

    r.calls.clear();
    r.keys('3 @ A');
    expect(r.calls.length, 9);
    expect(r.calls.first, 'roll.select.copyafter*2');
    r.calls.clear();
    r.keys('@ @');
    expect(r.calls.length, 3);
    expect(r.vim.keymap.serialize(), contains('macro "a"\n  roll.select.copyafter * 2'));
  });

  test('replaying a slot while recording it inlines its old steps, so no recursion', () {
    final r = Rig();
    r.keys('Alt+Q A W Alt+Q');
    r.keys('Alt+Q A @ A S Alt+Q');
    expect(r.vim.keymap.macros['a']!.steps.map((s) => s.ref.id), ['roll.notes.up', 'roll.notes.down']);
  });

  test('a self-calling macro on a key gives an error toast, not a hang', () {
    final r = Rig();
    r.vim.keymap.macros
        .put(Macro('loop', const [MacroStep(ActionRef.action('roll.notes.up')), MacroStep(ActionRef.macro('loop'))]));
    r.vim.keymap.bind(Area.pattern, KeySeq.parse('Ctrl+Shift+E'), const ActionRef.macro('loop'));
    final res = r.key('Ctrl+Shift+E');
    expect(res.error, isTrue);
    expect(res.toast, contains('calls itself'));
    expect(r.calls, isEmpty);
  });

  test('modes: insert passes keys through, visual marks selecting, Esc returns to normal', () {
    final r = Rig(area: Area.code);
    var notified = 0;
    r.vim.addListener(() => notified++);
    r.key('I');
    expect(r.vim.mode, VimMode.insert);
    expect(r.key('W').handled, isFalse);
    expect(r.key('Esc').handled, isTrue);
    expect(r.vim.mode, VimMode.normal);
    r.key('V');
    expect(r.vim.selecting, isTrue);
    r.key('S');
    expect(r.calls.last, 'code.vim.down*1');
    r.key('Esc');
    expect(r.vim.selecting, isFalse);

    final before = notified;
    r.keys('D D D');
    expect(notified, before, reason: 'plain movement changes nothing the badge shows');

    r.vim.area = Area.pattern;
    r.key('Shift+V');
    expect(r.vim.mode, VimMode.visual);
    r.key('Esc');
    r.key('Esc'); // in Normal, Esc runs the area's binding
    expect(r.calls.last, 'roll.select.none*1');
  });

  test('a toolbar tap runs through the controller and counts for . and recording', () {
    final r = Rig();
    r.vim.run(const ActionRef.action('roll.notes.quantize'));
    r.key('.');
    expect(r.calls, ['roll.notes.quantize*1', 'roll.notes.quantize*1']);
  });
}
