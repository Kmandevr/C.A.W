// Keymap tests: key chord parsing, the default keys, the file format round trip, merging, conflicts and reset.
import 'package:caw/actions/actions.dart';
import 'package:caw/actions/key_event.dart';
import 'package:caw/actions/keymap.dart';
import 'package:caw/actions/keys.dart';
import 'package:caw/actions/macro.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

KeySeq k(String s) => KeySeq.parse(s);

void main() {
  final reg = ActionRegistry.standard();
  final defaults = Keymap.defaults(reg);

  test('chords parse and format', () {
    expect(KeyChord.parse('ctrl+shift+w'), const KeyChord('W', ctrl: true, shift: true));
    expect(KeyChord.parse('Ctrl+Shift+W').format(), 'Ctrl+Shift+W');
    expect(KeyChord.parse('Alt+1'), const KeyChord('1', alt: true));
    expect(KeyChord.parse('?').key, '?');
    expect(KeyChord.parse('space').format(), 'Space');
    expect(KeyChord.parse('shift+f10').format(), 'Shift+F10');
    expect(KeyChord.parse('↑').format(), 'Up');
    expect(KeyChord.parse('Ctrl++'), const KeyChord('+', ctrl: true));
    expect(KeyChord.parse('Ctrl+='), const KeyChord('=', ctrl: true));
    expect(KeyChord.tryParse('Hyper+W'), isNull);
    expect(KeySeq.parse('C I W').length, 3);
    expect(KeySeq.parse('x  x'), KeySeq.parse('X X'));
  });

  test('key events become chords', () {
    const a = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        character: 'A',
        timeStamp: Duration.zero);
    expect(keyChordFromEvent(a, ctrl: false, shift: true, alt: false, meta: false), const KeyChord('A', shift: true));
    const at = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.digit2,
        logicalKey: LogicalKeyboardKey.digit2,
        character: '@',
        timeStamp: Duration.zero);
    expect(keyChordFromEvent(at, ctrl: false, shift: true, alt: false, meta: false), const KeyChord('@'));
    expect(keyChordFromEvent(at, ctrl: false, shift: false, alt: true, meta: false), const KeyChord('2', alt: true));
    const up = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.arrowUp, logicalKey: LogicalKeyboardKey.arrowUp, timeStamp: Duration.zero);
    expect(keyChordFromEvent(up, ctrl: true, shift: false, alt: false, meta: false), const KeyChord('Up', ctrl: true));
  });

  test('defaults include the owner keys', () {
    const p = Area.pattern;
    final want = {
      'W': 'roll.notes.up',
      'A': 'roll.notes.earlier',
      'S': 'roll.notes.down',
      'D': 'roll.notes.later',
      'Q': 'roll.notes.insert',
      'E': 'roll.select.copyafter',
      'Shift+A': 'roll.notes.shorter',
      'Shift+D': 'roll.notes.longer',
      'Shift+W': 'roll.notes.invertUp',
      'Shift+S': 'roll.notes.invertDown',
      'Ctrl+W': 'roll.cursor.up',
      'Ctrl+A': 'roll.cursor.left',
      'Ctrl+S': 'roll.cursor.down',
      'Ctrl+D': 'roll.cursor.right',
      'Ctrl+Shift+W': 'roll.cursor.jumpUp',
      'Ctrl+Shift+A': 'roll.cursor.jumpLeft',
      'Ctrl+Shift+S': 'roll.cursor.jumpDown',
      'Ctrl+Shift+D': 'roll.cursor.jumpRight',
      'Alt+1': 'roll.grid.div1',
      'Alt+5': 'roll.grid.div16',
      'Alt+8': 'roll.grid.div128',
      'Alt+0': 'roll.grid.triplets',
      'N': 'roll.grid.snap',
      'Alt+F': 'roll.grid.adaptive',
      'Alt+V': 'roll.view.velocityLane',
      'Alt+X': 'roll.view.extrasLanes',
      'Alt+Q': 'vim.record',
      'Space': 'transport.playstop',
    };
    want.forEach((keys, id) => expect(defaults.lookup(p, k(keys)), ActionRef.action(id), reason: keys));
    expect(defaults.lookup(Area.builder, k('Alt+L')), const ActionRef.action('builder.live.toggle'));
    expect(defaults.lookup(Area.code, k('D')), const ActionRef.action('code.vim.right'));
    expect(defaults.lookup(Area.code, k('X X')), const ActionRef.action('code.vim.deleteLine'));
    // Area keys win over global ones: Ctrl+S saves elsewhere but moves the cursor in the roll.
    expect(defaults.lookup(Area.arranger, k('Ctrl+S')), const ActionRef.action('arranger.layer.moveDown'));
    expect(defaults.lookup(Area.exporter, k('Ctrl+S')), const ActionRef.action('project.save'));
    expect(defaults.toolbars[Area.pattern]!.first, const ActionRef.action('roll.tool.draw'));
  });

  test('every default key runs its own action and no default sequence is blocked by a prefix', () {
    for (final d in reg.all) {
      for (final keys in d.defaultKeys) {
        expect(defaults.bindingsIn(d.area)[k(keys)], ActionRef.action(d.id), reason: '${d.id} $keys');
      }
    }
    expect(defaults.conflicts(includeShadows: false), isEmpty);
    expect(defaults.conflicts().where((c) => c.kind == ConflictKind.shadowsGlobal), isNotEmpty);
  });

  test('the file format round-trips', () {
    final km = defaults.copy()
      ..name = 'Mine'
      ..bind(Area.pattern, k('Ctrl+Shift+E'), const ActionRef.macro('Run of four'))
      ..macros.put(Macro('Run of four', const [
        MacroStep(ActionRef.action('roll.select.copyafter'), repeat: 3),
        MacroStep(ActionRef.action('roll.notes.up')),
        MacroStep(ActionRef.action('transport.bpm'), arg: '140'),
      ]));
    final text = km.serialize();
    final warnings = <String>[];
    final back = Keymap.parse(text, registry: reg, warnings: warnings);
    expect(warnings, isEmpty);
    expect(back.serialize(), text);
    expect(back.name, 'Mine');
    expect(back.lookup(Area.pattern, k('Ctrl+Shift+E')), const ActionRef.macro('Run of four'));
    expect(back.macros['Run of four']!.steps.first.repeat, 3);
    expect(back.macros['Run of four']!.steps.last.arg, '140');
  });

  test('the doc example parses', () {
    const text = '''---
kind: keymap
name: My keys
---
# area      keys            action
roll        W               roll.notes.up
roll        Ctrl+W          roll.cursor.up
global      Space           transport.playstop
roll        Ctrl+Shift+E    macro "Run of four"

macro "Run of four"
  roll.select.copyafter * 3
  roll.notes.up
''';
    final warnings = <String>[];
    final km = Keymap.parse(text, registry: reg, warnings: warnings);
    expect(warnings, isEmpty);
    expect(km.bindingsIn(Area.pattern).length, 3);
    expect(km.macros['Run of four']!.steps, const [
      MacroStep(ActionRef.action('roll.select.copyafter'), repeat: 3),
      MacroStep(ActionRef.action('roll.notes.up')),
    ]);
  });

  test('bad lines are warnings, a wrong header is an error', () {
    final warnings = <String>[];
    Keymap.parse('---\nkind: keymap\n---\nnowhere W roll.notes.up\nroll Hyper+W roll.notes.up\nroll W nope.nope\n',
        registry: reg, warnings: warnings);
    expect(warnings.length, 3);
    expect(() => Keymap.parse('---\nkind: theme\n---\n'), throwsFormatException);
    expect(() => Keymap.parse('roll W roll.notes.up'), throwsFormatException);
  });

  test('a user keymap merges over the defaults, and diffs back out', () {
    final user = Keymap(name: 'Mine')
      ..bind(Area.pattern, k('Q'), const ActionRef.action('roll.notes.delete'))
      ..unbind(Area.pattern, k('E'), record: true)
      ..toolbars[Area.pattern] = [const ActionRef.action('edit.undo')];
    final merged = user.mergedOver(defaults);
    expect(merged.lookup(Area.pattern, k('Q')), const ActionRef.action('roll.notes.delete'));
    expect(merged.lookup(Area.pattern, k('E')), isNull);
    expect(merged.lookup(Area.pattern, k('W')), const ActionRef.action('roll.notes.up'));
    expect(merged.toolbars[Area.pattern], [const ActionRef.action('edit.undo')]);

    final diff = merged.serialize(base: defaults);
    expect(diff, contains('roll        Q               roll.notes.delete'));
    expect(diff, contains('roll        E               -'));
    final again = Keymap.parse(diff, registry: reg).mergedOver(defaults);
    expect(again.serialize(), merged.serialize());
  });

  test('conflicts are found per area', () {
    final c = defaults.conflictsFor(Area.pattern, k('E'));
    expect(c.single.kind, ConflictKind.taken);
    expect(c.single.existing, const ActionRef.action('roll.select.copyafter'));
    expect(defaults.conflictsFor(Area.code, k('X')).single.kind, ConflictKind.prefix);
    expect(defaults.conflictsFor(Area.pattern, k('T')).single.kind, ConflictKind.shadowsGlobal);
    expect(defaults.conflictsFor(Area.global, k('Ctrl+S')).map((c) => c.area), contains(Area.pattern));
    expect(defaults.conflictsFor(Area.pattern, k('Alt+9')), isEmpty);

    final km = defaults.copy()..bind(Area.pattern, k('Q Q'), const ActionRef.action('roll.notes.delete'));
    expect(km.conflicts(includeShadows: false).single.keys, k('Q Q'));
  });

  test('reset puts one area back', () {
    final km = defaults.copy()
      ..bind(Area.pattern, k('Q'), const ActionRef.action('roll.notes.delete'))
      ..bind(Area.arranger, k('Q'), const ActionRef.action('arranger.layer.mute'))
      ..toolbars[Area.pattern] = [];
    km.resetArea(Area.pattern, defaults);
    expect(km.lookup(Area.pattern, k('Q')), const ActionRef.action('roll.notes.insert'));
    expect(km.toolbars[Area.pattern], defaults.toolbars[Area.pattern]);
    expect(km.lookup(Area.arranger, k('Q')), const ActionRef.action('arranger.layer.mute'));
    km.resetAll(defaults);
    expect(km.serialize(base: defaults).trim().split('\n').length, 5);
  });

  test('the registry finds actions by area, command and search', () {
    expect(reg.inArea(Area.exporter).map((d) => d.id), contains('export.now'));
    expect(reg.matchCommand('bpm').single.id, 'transport.bpm');
    expect(reg.matchCommand('quantize').single.id, 'roll.notes.quantize');
    expect(reg.search('copy after').first.id, 'roll.select.copyafter');
    expect(() => reg.register(const ActionDef('edit.undo', 'Again', Area.global)), throwsArgumentError);
  });

  test('project macros merge after the app macros', () {
    final app = MacroSet([
      Macro('a', const [MacroStep(ActionRef.action('edit.undo'))])
    ]);
    final project = MacroSet([
      Macro('a', const [MacroStep(ActionRef.action('edit.redo'))]),
      Macro('b', const [])
    ]);
    final m = MacroSet.merged(app, project);
    expect(m['a']!.steps.single.ref.id, 'edit.redo');
    expect(m.names, ['a', 'b']);
    expect(MacroSet.parse(m.format())['a'], m['a']);
    expect(MacroSet.fromJson(m.toJson())['a'], m['a']);
  });
}
