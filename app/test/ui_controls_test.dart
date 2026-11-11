// Generated UI for a component's declared UI controls (#10): grouping, the XY pad, a momentary button, a curve, narrowed ranges, inline in the FX stack and goldens.
import 'package:caw/engine/component_info.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/project.dart';
import 'package:caw/ui/devices/device_editor.dart';
import 'package:caw/ui/devices/device_inline.dart';
import 'package:caw/ui/devices/generic_device_page.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

const _id = 'local.stutter.fx';

/// A user's C++ effect that declares one control of every kind.
NativeComponentInfo stutterInfo() => NativeComponentInfo.fromJson({
      'id': _id, 'name': 'Stutter box', 'role': 'effect',
      'ports': [
        {'id': 'in', 'type': 'audio', 'input': true, 'layout': 'stereo', 'channels': 2},
        {'id': 'out', 'type': 'audio', 'input': false, 'layout': 'stereo', 'channels': 2},
      ],
      'parameters': [
        {'id': 'cutoff', 'name': 'Cutoff', 'unit': 'Hz', 'default': 1000, 'min': 20, 'max': 20000, 'curve': 'exponential'},
        {'id': 'reso', 'name': 'Resonance', 'default': 0.2, 'min': 0, 'max': 1},
        {'id': 'hold', 'name': 'Hold', 'default': 0, 'min': 0, 'max': 1, 'step': 1, 'choices': ['Off', 'On']},
        {'id': 'freeze', 'name': 'Freeze', 'default': 0, 'min': 0, 'max': 1, 'step': 1, 'choices': ['Off', 'On']},
        {'id': 'mode', 'name': 'Mode', 'default': 0, 'min': 0, 'max': 2, 'step': 1, 'choices': ['Soft', 'Hard', 'Fold']},
        {'id': 'shape', 'name': 'Shape', 'default': 0, 'min': -1, 'max': 1},
        {'id': 'mix', 'name': 'Mix', 'default': 1, 'min': 0, 'max': 1},
        {'id': 'drive', 'name': 'Drive', 'unit': 'dB', 'default': 0, 'min': 0, 'max': 24},
      ],
      'ui_controls': [
        {'id': 'pad-x', 'label': 'Filter', 'parameter_id': 'cutoff', 'kind': 'xy_pad', 'min': 20, 'max': 20000},
        {'id': 'pad-y', 'label': 'Filter', 'parameter_id': 'reso', 'kind': 'xy_pad', 'min': 0, 'max': 1},
        {'id': 'hold', 'label': 'Stutter', 'parameter_id': 'hold', 'kind': 'button', 'min': 0, 'max': 1},
        {'id': 'freeze', 'label': '', 'parameter_id': 'freeze', 'kind': 'toggle', 'min': 0, 'max': 1},
        {'id': 'random', 'label': 'Randomize', 'parameter_id': '', 'kind': 'button', 'min': 0, 'max': 1},
        {'id': 'mode', 'label': 'Mode', 'parameter_id': 'mode', 'kind': 'dropdown', 'min': 0, 'max': 2},
        {'id': 'shape', 'label': 'Shape', 'parameter_id': 'shape', 'kind': 'curve', 'min': -1, 'max': 1},
        {'id': 'mix', 'label': 'Mix', 'parameter_id': 'mix', 'kind': 'slider', 'min': 0, 'max': 0.5},
        {'id': 'ghost', 'label': 'Gone', 'parameter_id': 'missing', 'kind': 'slider', 'min': 0, 'max': 1},
      ],
    });

AppState stutterState() {
  final s = PreviewState();
  s.project = ProjectDoc(id: 'p', name: 'Devices', bpm: 120, modules: [], layers: [LayerDoc(id: 'a', name: 'Track', color: 2)]);
  s.componentCatalog.set([...builtinInfos(), stutterInfo()]);
  s.addNativeEffect(s.project.layers.first, _id);
  return s;
}

void main() {
  var motion = MotionLevel.full;
  final states = <AppState>[];
  setUp(() {
    motion = Motion.setting;
    Motion.setting = MotionLevel.off;
  });
  tearDown(() {
    Motion.setting = motion;
    for (final s in states) {
      s.dispose();
    }
    states.clear();
  });

  Future<AppState> open(WidgetTester tester, {Size size = const Size(390, 844)}) async {
    final s = stutterState();
    states.add(s);
    late BuildContext ctx;
    await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    })), size);
    openDeviceEditor(ctx, s, s.project.layers.first, 0);
    await tester.pumpAndSettle();
    return s;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  double v(AppState s, String id) => DeviceTarget(s, 'a', 0).value(id);

  test('controls group: XY pairs, pills share a row, unknown parameters are left out', () {
    final g = groupUiControls(stutterInfo());
    expect(g.length, 5);
    expect(g[0], isA<UiXYGroup>().having((x) => x.y?.parameterId, 'y', 'reso'));
    expect(g[1], isA<UiPillGroup>().having((p) => p.controls.map((c) => c.id), 'ids', ['hold', 'freeze', 'random']));
    expect((g[2] as UiSingleGroup).control.kind, 'dropdown');
    expect((g[3] as UiSingleGroup).control.kind, 'curve');
    expect((g[4] as UiSingleGroup).control.id, 'mix');
  });

  test('a curve bends from x^8 to x^(1/8), straight in the middle', () {
    expect(UiCurve.shape(0.5, 0), closeTo(0.5, 1e-9));
    expect(UiCurve.shape(0.5, 1), greaterThan(0.9));
    expect(UiCurve.shape(0.5, -1), lessThan(0.01));
  });

  testWidgets('the generated page: the pad drags both knobs, the button holds, the curve bends, ranges narrow', (tester) async {
    final s = await open(tester);
    expect(find.byKey(const ValueKey('device-generated')), findsOneWidget);
    expect(find.text('Gone'), findsNothing);
    final c0 = v(s, 'cutoff'), r0 = v(s, 'reso');
    await tester.drag(find.byKey(const ValueKey('xy-cutoff-reso')), const Offset(60, -40));
    await tester.pumpAndSettle();
    expect(v(s, 'cutoff'), greaterThan(c0));
    expect(v(s, 'reso'), greaterThan(r0));

    final button = find.byKey(const ValueKey('ui-button-hold'));
    final g = await tester.startGesture(tester.getCenter(button));
    await tester.pump();
    expect(v(s, 'hold'), 1);
    await g.up();
    await tester.pump();
    expect(v(s, 'hold'), 0);

    await tester.tap(find.byKey(const ValueKey('toggle-freeze')));
    await tester.pump();
    expect(v(s, 'freeze'), 1);

    await tester.tap(find.byKey(const ValueKey('dchoice-mode-2')));
    await tester.pump();
    expect(v(s, 'mode'), 2);

    await tester.drag(find.byKey(const ValueKey('curve-shape')), const Offset(0, -40));
    await tester.pumpAndSettle();
    expect(v(s, 'shape'), greaterThan(0));

    // Mix's control spans 0..0.5: a drag to the far right stops there.
    final mix = find.byKey(const ValueKey('dslider-mix'));
    await tester.ensureVisible(mix);
    await tester.drag(mix, const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(v(s, 'mix'), closeTo(0.5, 1e-9));

    // Drive has no control: it waits under MORE.
    expect(find.byKey(const ValueKey('device-fold')), findsOneWidget);
    await close(tester);
  });

  testWidgets('a component with UI controls shows inline in the FX stack', (tester) async {
    final s = stutterState();
    states.add(s);
    expect(hasInlineDevice(DeviceTarget(s, 'a', 0)), isTrue);
    await pumpGolden(tester, Scaffold(body: SingleChildScrollView(child: DeviceInline(target: DeviceTarget(s, 'a', 0)))),
        const Size(390, 844));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('device-generated')), findsOneWidget);
    await close(tester);
  });

  for (final size in ['phone', 'desktop']) {
    testWidgets('golden: generated controls ($size)', (tester) async {
      await open(tester, size: goldenSizes[size]!);
      await expectLater(goldenScreen, matchesGoldenFile('goldens/ui_controls_$size.png'));
      await close(tester);
    });
  }
}
