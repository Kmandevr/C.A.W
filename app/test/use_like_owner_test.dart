// Every built-in device used the way the owner uses it on a phone (1.1.3-alpha.1, "most of the knobs and all of the effects don't do anything"): each device of the library on a new project's track, its page at phone size, and every control on it touched with a real finger and a mouse; the value must move and reach the engine.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:caw/engine/component_info.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/merged_devices.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/knob.dart' show Taper;
import 'package:caw/ui/devices/device_editor.dart';
import 'package:caw/ui/devices/kit/touch_engage.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart' show FakeDisplay, builtinInfos, fakeFrame;

/// A stand-in engine that records what the app sends it while a finger works a page.
class RecordingEngine implements Engine {
  final sent = <(String? layer, int index, String param, double value)>[];

  /// Every parameter the app moved, for the real engine's check.
  final moved = <(String? layer, int index, String param)>{};

  @override
  bool setComponentParam(String? layerId, int index, String param, double value) {
    sent.add((layerId, index, param, value));
    moved.add((layerId, index, param));
    return true;
  }

  @override
  Future<Map<String, ModuleInfo>> setProject(String json) async => const {};

  @override
  Future<List<NativeComponentInfo>> nativeComponents() async => _catalog;

  @override
  List<String> lastProjectWarnings = const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// One device of the library: a component and, for a merged device, its variant.
typedef DeviceCase = ({NativeComponentInfo info, int? variant});

/// Every built-in instrument and effect (each variant of a merged one) the catalog lists, so a new device is covered
/// as soon as the engine has it. Modulators and racks have pages of their own kind and are left out.
List<DeviceCase> deviceCases(List<NativeComponentInfo> catalog) => [
      for (final c in catalog)
        if (isBuiltinComponent(c.id) && !c.id.startsWith('org.caw.mod.') && !c.id.startsWith('org.caw.rack.') &&
            !ComponentUseDoc.retiredInstruments.contains(c.id) && !MergedDevices.isRetired(c.id))
          if (c.variants.length < 2) (info: c, variant: null)
          else for (var v = 0; v < c.variants.length; v++) (info: c, variant: v),
    ];

/// The catalog: the engine's own (CAW_LIB) or the test fixture's.
List<NativeComponentInfo> _catalog = builtinInfos();
Engine? _real;

const phone = Size(412, 915);

/// How one control kind answers the owner's gestures.
enum Kind { knob, slider, choice, mode, toggle, power, xy }

({Kind kind, String param, int? choice, String? param2})? _parse(Key? key) {
  if (key is! ValueKey<String>) return null;
  final k = key.value;
  RegExpMatch? m;
  if ((m = RegExp(r'^dknob-(.+)$').firstMatch(k)) != null) return (kind: Kind.knob, param: m!.group(1)!, choice: null, param2: null);
  if ((m = RegExp(r'^dslider-(.+)$').firstMatch(k)) != null) return (kind: Kind.slider, param: m!.group(1)!, choice: null, param2: null);
  if ((m = RegExp(r'^dchoice-(.+)-(\d+)$').firstMatch(k)) != null) {
    return (kind: Kind.choice, param: m!.group(1)!, choice: int.parse(m.group(2)!), param2: null);
  }
  if ((m = RegExp(r'^mode-(.+)-(\d+)$').firstMatch(k)) != null) {
    return (kind: Kind.mode, param: m!.group(1)!, choice: int.parse(m.group(2)!), param2: null);
  }
  if ((m = RegExp(r'^toggle-(.+)$').firstMatch(k)) != null) return (kind: Kind.toggle, param: m!.group(1)!, choice: null, param2: null);
  if ((m = RegExp(r'^dpower-(.+)$').firstMatch(k)) != null) return (kind: Kind.power, param: m!.group(1)!, choice: null, param2: null);
  return null;
}

/// A finger's gestures, at a phone's pace (a frame is 16 ms).
Future<void> fingerDrag(WidgetTester tester, Offset at, Offset step, int steps,
    {Duration rest = Duration.zero, Duration frame = const Duration(milliseconds: 16),
    PointerDeviceKind kind = PointerDeviceKind.touch}) async {
  final g = await tester.startGesture(at, kind: kind);
  if (rest > Duration.zero) await tester.pump(rest);
  for (var i = 0; i < steps; i++) {
    await g.moveBy(step);
    await tester.pump(frame);
  }
  await g.up();
  await tester.pump(const Duration(milliseconds: 50));
}

class Finding {
  Finding(this.device, this.control, this.gesture, this.what);
  final String device, control, gesture, what;
  @override
  String toString() => '$device · $control · $gesture: $what';
}

Future<void> main() async {
  final lib = Platform.environment['CAW_LIB'];
  final withLib = lib != null && lib.isNotEmpty;
  // An Android phone's touch slop (MediaQuery.gestureSettings: about 8 logical px, where the page's scroll and
  // swipe panels claim a move), not kTouchSlop's 18; CAW_SLOP=18 runs as a test does by default.
  final slop = double.tryParse(Platform.environment['CAW_SLOP'] ?? '') ?? 8;
  final only = Platform.environment['CAW_ONLY'];
  late DeviceDisplaySource source;
  var motion = MotionLevel.full;

  if (withLib) {
    _real = Engine.create();
    _catalog = await _real!.nativeComponents();
  }

  setUp(() {
    motion = Motion.setting;
    source = DeviceDisplaySource.current;
    DeviceDisplaySource.current = FakeDisplay()..frame.value = null;
  });
  tearDown(() {
    Motion.setting = motion;
    DeviceDisplaySource.current = source;
    KnobDrag.sideways = true;
  });

  /// A new project with one track, [c] added to it the way the library adds it, and its page open at phone size.
  Future<(AppState, DeviceTarget, RecordingEngine)> open(WidgetTester tester, DeviceCase c, {bool sideways = true}) async {
    final s = AppState(settings: Settings()..knobSideways = sideways);
    KnobDrag.sideways = sideways;
    Motion.setting = MotionLevel.off;
    s.project = ProjectDoc(id: 'p', name: 'New', bpm: 120, modules: [], layers: [LayerDoc(id: 'a', name: 'Track 1', color: 2)]);
    s.componentCatalog.set(_catalog);
    final layer = s.project.layers.first;
    final int slot;
    if (c.info.isInstrument) {
      s.setNativeInstrument(layer, c.info.id);
      if (c.variant != null) layer.instrument!.params['variant'] = c.variant!.toDouble();
      slot = DeviceTarget.instrumentSlot;
    } else {
      final use = s.addNativeEffect(layer, c.info.id)!;
      if (c.variant != null) use.params['variant'] = c.variant!.toDouble();
      slot = 0;
    }
    final engine = RecordingEngine();
    s.engine = engine;
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1;
    tester.view.gestureSettings = ui.GestureSettings(physicalTouchSlop: slop);
    addTearDown(tester.view.reset);
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    }))));
    openDeviceEditor(ctx, s, layer, slot);
    await tester.pumpAndSettle();
    DeviceFakeFrame.frame(c.info.id);
    return (s, DeviceTarget(s, 'a', slot), engine);
  }

  String name(DeviceCase c) => c.variant == null ? c.info.id : '${c.info.id}#${c.variant}';

  /// Works every control on the page; the findings (empty when every control answered).
  Future<List<Finding>> work(WidgetTester tester, DeviceCase c, AppState s, DeviceTarget t, RecordingEngine engine) async {
    final findings = <Finding>[];
    final dev = name(c);
    final layer = s.project.layers.first;
    final index = t.isInstrument ? ProjectDoc.instrumentIndex : s.engineComponentIndex(layer, t.slot);
    final done = <String>{};

    double value(String p) => t.value(p);
    void middle(String p) {
      final info = t.param(p);
      if (info == null) return;
      t.set(p, Taper(info.min, info.max, exponential: info.exponential).value(0.5));
    }

    bool reached(String p, String gesture, String control) {
      final last = engine.sent.where((e) => e.$3 == p).lastOrNull;
      if (last == null) {
        findings.add(Finding(dev, control, gesture, 'value moved but nothing was sent to the engine'));
        return false;
      }
      if (last.$2 != index || last.$1 != 'a' || (last.$4 - value(p)).abs() > 1e-9) {
        findings.add(Finding(dev, control, gesture, 'sent ${last.$1}/${last.$2} ${last.$4}, expected a/$index ${value(p)}'));
        return false;
      }
      return true;
    }

    Future<void> knob(Finder f, String p, String control) async {
      Offset at() => tester.getCenter(f);
      // A sideways finger drag, slightly off horizontal as a thumb moves.
      middle(p);
      await tester.pump();
      var before = value(p);
      engine.sent.clear();
      await fingerDrag(tester, at(), KnobDrag.sideways ? const Offset(5, -1.5) : const Offset(0, -5), 12);
      if (value(p) == before) {
        findings.add(Finding(dev, control, KnobDrag.sideways ? 'finger sideways' : 'finger up', 'did not move'));
      } else {
        reached(p, 'finger sideways', control);
      }
      // A quick vertical swipe: the page's (both settings leave it to the scroll).
      middle(p);
      await tester.pump();
      if (f.hitTestable().evaluate().isEmpty) return;
      before = value(p);
      await fingerDrag(tester, at(), const Offset(0, -14), 7, frame: const Duration(milliseconds: 8));
      await tester.pumpAndSettle();
      if (value(p) != before) findings.add(Finding(dev, control, 'quick vertical swipe', 'turned the knob'));
      if (f.hitTestable().evaluate().isEmpty) return;
      // A rest, then a vertical drag: the knob's.
      middle(p);
      await tester.pump();
      before = value(p);
      engine.sent.clear();
      await fingerDrag(tester, at(), const Offset(0, -6), 10, rest: const Duration(milliseconds: 300));
      if (value(p) == before) {
        findings.add(Finding(dev, control, 'hold then vertical', 'did not move'));
      } else {
        reached(p, 'hold then vertical', control);
      }
      await tester.pumpAndSettle();
      if (f.hitTestable().evaluate().isEmpty) return;
      // A mouse drag up: at once.
      middle(p);
      await tester.pump();
      before = value(p);
      engine.sent.clear();
      await fingerDrag(tester, at(), const Offset(0, -6), 10, kind: PointerDeviceKind.mouse);
      if (value(p) == before) {
        findings.add(Finding(dev, control, 'mouse drag', 'did not move'));
      } else {
        reached(p, 'mouse drag', control);
      }
    }

    Future<void> slider(Finder f, String p, String control) async {
      for (final (gesture, kind) in [('finger sideways', PointerDeviceKind.touch), ('mouse drag', PointerDeviceKind.mouse)]) {
        final r = tester.getRect(f);
        t.set(p, t.param(p)!.min);
        await tester.pump();
        final before = value(p);
        engine.sent.clear();
        await fingerDrag(tester, Offset(r.left + r.width * 0.3, r.center.dy), const Offset(6, -1), 8, kind: kind);
        if (value(p) == before) {
          findings.add(Finding(dev, control, gesture, 'did not move'));
        } else {
          reached(p, gesture, control);
        }
      }
    }

    Future<void> tap(Finder f, String p, String control, double Function(double before) expect) async {
      final before = value(p);
      final want = expect(before);
      engine.sent.clear();
      await tester.tap(f, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 400));
      if (value(p) != want) {
        findings.add(Finding(dev, control, 'tap', 'value ${value(p)}, expected $want'));
      } else if (want != before) {
        reached(p, 'tap', control);
      }
    }

    // Every panel of every section: the tabs, the swipe panels inside them, and the vertical scroll of each.
    final tabs = find.byWidgetPredicate((w) => w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('device-tab-'));
    final tabKeys = [for (final e in tabs.evaluate()) e.widget.key!];
    for (var ti = 0; ti < (tabKeys.isEmpty ? 1 : tabKeys.length); ti++) {
      if (tabKeys.isNotEmpty) {
        await tester.tap(find.byKey(tabKeys[ti]).first, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
      final pagers = find.byType(PageView).evaluate().toList();
      final pageCount = pagers.isEmpty ? 1 : ((pagers.first.widget as PageView).childrenDelegate.estimatedChildCount ?? 1);
      for (var pi = 0; pi < pageCount; pi++) {
        if (pagers.isNotEmpty) {
          final pv = tester.widget<PageView>(find.byType(PageView).first);
          pv.controller?.jumpToPage(pi);
          await tester.pumpAndSettle();
        }
        // Down the page's scroll, a screen at a time.
        final scrolls = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
        ScrollPosition? pos;
        for (final e in scrolls.evaluate()) {
          final st = (e as StatefulElement).state as ScrollableState;
          if (st.position.maxScrollExtent > 0 && (pos == null || st.position.maxScrollExtent > pos.maxScrollExtent)) {
            pos = st.position;
          }
        }
        for (var off = 0.0;; off += 300) {
          if (pos != null) {
            pos.jumpTo(off.clamp(0, pos.maxScrollExtent));
            await tester.pumpAndSettle();
          }
          final screen = Offset.zero & phone;
          final candidates = <(Key, ({Kind kind, String param, int? choice, String? param2}))>[];
          for (final e in find.byWidgetPredicate((w) => _parse(w.key) != null).hitTestable().evaluate()) {
            final key = e.widget.key!;
            final id = '$key';
            if (done.contains(id)) continue;
            final box = e.renderObject as RenderBox?;
            if (box == null || !box.hasSize) continue;
            final r = box.localToGlobal(Offset.zero) & box.size;
            // Fully on screen, clear of the editor's header and footer.
            if (!screen.deflate(4).contains(r.topLeft) || !screen.deflate(4).contains(r.bottomRight)) continue;
            candidates.add((key, _parse(key)!));
          }
          for (final (key, c) in candidates) {
            final f = find.byKey(key).first;
            if (f.hitTestable().evaluate().isEmpty) continue;
            done.add('$key');
            if (t.param(c.param) == null) continue;
            final control = '${c.kind.name} ${c.param}${c.choice == null ? '' : '=${c.choice}'}';
            final save = pos?.pixels;
            switch (c.kind) {
              case Kind.knob:
                await knob(f, c.param, control);
              case Kind.slider:
                await slider(f, c.param, control);
              case Kind.choice || Kind.mode:
                await tap(f, c.param, control, (_) => t.param(c.param)!.min + c.choice!);
              case Kind.toggle:
                await tap(f, c.param, control, (b) {
                  final p = t.param(c.param)!;
                  return b >= (p.min + p.max) / 2 ? p.min : p.max;
                });
              case Kind.power:
                await tap(f, c.param, control, (b) => b >= 0.5 ? t.param(c.param)!.min : t.param(c.param)!.max);
              case Kind.xy:
                break;
            }
            if (pos != null && save != null && pos.hasPixels) {
              pos.jumpTo(save.clamp(0, pos.maxScrollExtent));
              await tester.pumpAndSettle();
            }
          }
          if (pos == null || off >= pos.maxScrollExtent) break;
        }
      }
    }
    if (done.isEmpty) findings.add(Finding(dev, '-', '-', 'no controls found on the page'));
    return findings;
  }

  final cases = deviceCases(_catalog).where((c) => only == null || name(c).contains(only)).toList();
  group('every control of every device answers the owner\'s finger', () {
    for (final c in cases) {
      testWidgets(name(c), (tester) async {
        final (s, t, engine) = await open(tester, c);
        final findings = await work(tester, c, s, t, engine);
        // With the engine (CAW_LIB): the project as the app sends it plays this device, and each parameter the page
        // moved is one the playing chain has at the index the app sent it to.
        final real = _real;
        if (real != null) {
          await tester.runAsync(() => real.setProject(s.engineJsonOf(s.project)));
          for (final m in engine.moved) {
            if (!real.setComponentParam(m.$1, m.$2, m.$3, t.value(m.$3))) {
              findings.add(Finding(name(c), m.$3, 'engine', 'the playing chain has no ${m.$3} at ${m.$1}/${m.$2}'));
            }
          }
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        s.dispose();
        expect(findings, isEmpty, reason: findings.join('\n'));
      });
    }
  });
}

/// Puts a playing frame on the fake display, so pages that draw from it lay out as they do when playing.
abstract final class DeviceFakeFrame {
  static void frame(String id) {
    final d = DeviceDisplaySource.current;
    if (d is FakeDisplay) d.frame.value = fakeFrame(id);
  }
}
