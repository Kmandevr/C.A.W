// Macro tests: expansion with repeats, nested macros, the recursion guard, the step cap and async handlers.
import 'dart:async';

import 'package:caw/actions/actions.dart';
import 'package:caw/actions/macro.dart';
import 'package:flutter_test/flutter_test.dart';

const up = ActionRef.action('roll.notes.up');
const copy = ActionRef.action('roll.select.copyafter');

void main() {
  final reg = ActionRegistry.standard();

  MacroRunner runner(MacroSet set, List<String> log, {int maxSteps = 10000}) => MacroRunner.forSet(set,
      registry: reg,
      maxSteps: maxSteps,
      handler: (id, {int count = 1, String? arg}) => log.add('$id*$count${arg == null ? '' : ' $arg'}'));

  test('steps run in order with their repeat as the count', () {
    final log = <String>[];
    final set = MacroSet([
      Macro('Run of four', const [MacroStep(copy, repeat: 3), MacroStep(up)]),
      Macro('Twice', const [
        MacroStep(ActionRef.macro('Run of four'), repeat: 2),
        MacroStep(ActionRef.action('transport.bpm'), arg: '140')
      ]),
    ]);
    expect(runner(set, log).run(const ActionRef.macro('Twice')), isNull);
    expect(log, [
      'roll.select.copyafter*3',
      'roll.notes.up*1',
      'roll.select.copyafter*3',
      'roll.notes.up*1',
      'transport.bpm*1 140',
    ]);
    log.clear();
    runner(set, log).run(const ActionRef.macro('Run of four'), count: 2);
    expect(log.length, 4);
  });

  test('a macro that calls itself, or a cycle, is an error before anything runs', () {
    final log = <String>[];
    final set = MacroSet([
      Macro('self', const [MacroStep(up), MacroStep(ActionRef.macro('self'))]),
      Macro('a', const [MacroStep(ActionRef.macro('b'))]),
      Macro('b', const [MacroStep(up), MacroStep(ActionRef.macro('a'))]),
    ]);
    final r = runner(set, log);
    expect(() => r.run(const ActionRef.macro('self')), throwsA(isA<MacroError>()));
    expect(r.check('self'), contains('calls itself'));
    expect(r.check('a'), contains('call each other'));
    expect(r.check('missing'), contains('No macro'));
    expect(log, isEmpty);
  });

  test('the total step cap stops runaway repeats', () {
    final log = <String>[];
    final set = MacroSet([
      Macro('big', const [MacroStep(up, repeat: 600)]),
      Macro('huge', const [MacroStep(ActionRef.macro('big'), repeat: 20)]),
      Macro('empty', const []),
      Macro('many empty', const [MacroStep(ActionRef.macro('empty'), repeat: 1000000000)]),
    ]);
    final r = runner(set, log, maxSteps: 10000);
    expect(r.expand(const ActionRef.macro('big')).single.count, 600);
    expect(r.check('huge'), contains('Too many steps'));
    expect(r.expand(const ActionRef.macro('many empty')), isEmpty);
    expect(log, isEmpty);
  });

  test('unknown actions are errors', () {
    final r = runner(
        MacroSet([
          Macro('x', const [MacroStep(ActionRef.action('no.such'))])
        ]),
        []);
    expect(r.check('x'), contains('Unknown action'));
  });

  test('async handlers run one after another', () async {
    final log = <String>[];
    final gates = <Completer<void>>[];
    final r = MacroRunner.forSet(
        MacroSet([
          Macro('m', const [MacroStep(up), MacroStep(copy)])
        ]), handler: (id, {int count = 1, String? arg}) {
      log.add(id);
      final c = Completer<void>();
      gates.add(c);
      return c.future;
    });
    final first = r.run(const ActionRef.macro('m'));
    final second = r.run(up);
    expect(log, ['roll.notes.up']);
    gates.last.complete();
    await Future<void>.delayed(Duration.zero);
    expect(log, ['roll.notes.up', 'roll.select.copyafter']);
    gates.last.complete();
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(log.length, 3);
    gates.last.complete();
    await second;
  });

  test('steps parse and format', () {
    expect(MacroStep.parse('roll.select.copyafter * 3'), const MacroStep(copy, repeat: 3));
    expect(MacroStep.parse('roll.grid.set 1/16'), const MacroStep(ActionRef.action('roll.grid.set'), arg: '1/16'));
    expect(MacroStep.parse('macro "Run of four" * 2').ref, const ActionRef.macro('Run of four'));
    expect(MacroStep.parse('roll.key.set A minor * 2').format(), 'roll.key.set A minor * 2');
    expect(() => MacroStep.parse('roll.notes.up * 0'), throwsFormatException);
  });
}
