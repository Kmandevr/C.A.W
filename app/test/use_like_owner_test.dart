// Every built-in device used the way the owner uses it on a phone (1.1.3-alpha.1, "most of the knobs and all of the effects don't do anything"): each device of the library on a new project's track, its page at phone size, and every control on it touched with a real finger and a mouse; the value must move and reach the engine.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:caw/engine/component_info.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/files_catalog.dart';
import 'package:caw/model/merged_devices.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/templates.dart';
import 'package:caw/ui/arrange/knob.dart' show Knob, Taper;
import 'package:caw/ui/devices/device_editor.dart';
import 'package:caw/ui/devices/device_controls.dart' show DeviceKnob;
import 'package:caw/ui/devices/kit/grab_gesture.dart';
import 'package:caw/ui/devices/kit/touch_engage.dart';
import 'package:caw/ui/devices/visuals/grab.dart';
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
  Future<bool> setComponentState(String? layerId, int index, Uint8List bytes, int version) async => true;

  @override
  Map<int, ({String state, int version})> componentStates(String? layerId) => const {};

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
            c.role != 'event_processor' &&  // MIDI effects: not in the library (files_catalog.dart)
            !ComponentUseDoc.retiredInstruments.contains(c.id) && !MergedDevices.isRetired(c.id))
          if (c.variants.length < 2) (info: c, variant: null)
          else for (var v = 0; v < c.variants.length; v++) (info: c, variant: v),
    ];

/// The catalog: the engine's own (CAW_LIB) or the test fixture's.
List<NativeComponentInfo> _catalog = [
  ...builtinInfos(),
  for (final f in ['timber_component', 'sampler_component'])
    ...NativeComponentInfo.listFromJson(
        jsonDecode(File('test/fixtures/$f.json').readAsStringSync()) as Map<String, dynamic>),
];
Engine? _real;

const phone = Size(412, 915);
const _frame = Duration(milliseconds: 16);

/// Closes a sheet or menu a gesture left open (a knob's hold menu), so the page is in front again.
Future<void> _dismiss(WidgetTester tester) async {
  for (var i = 0; i < 3 && find.byType(BottomSheet).evaluate().isNotEmpty; i++) {
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
  }
}

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
  if ((m = RegExp(r'^chip-(.+)-(\d+)$').firstMatch(k)) != null) {
    return (kind: Kind.mode, param: m!.group(1)!, choice: int.parse(m.group(2)!), param2: null);
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
    // New project, as the project menu makes it (the default template), on its first track that plays notes.
    s.project = s.newProjectDoc();
    s.componentCatalog.set(_catalog);
    var layer = s.project.layers.where((l) => !l.isFolder && !l.isAudio && l.instrument != null).firstOrNull;
    if (layer == null) {
      layer = LayerDoc(id: 'a', name: 'Track 1', color: 2);
      s.project.layers.add(layer);
      s.setNativeInstrument(layer, 'org.caw.synth.flagship');
    }
    final int slot;
    if (c.info.isInstrument) {
      s.setNativeInstrument(layer, c.info.id);
      if (c.variant != null) layer.instrument!.params['variant'] = c.variant!.toDouble();
      slot = DeviceTarget.instrumentSlot;
    } else {
      final use = s.addNativeEffect(layer, c.info.id)!;
      if (c.variant != null) use.params['variant'] = c.variant!.toDouble();
      slot = layer.components.length - 1;
    }
    // The page opens on the new device: an effect at the end of the track's chain.
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
    // A page that runs off a phone's width is a layout bug of its own (reported, not this suite's question): Talon's
    // Bus chips with the engine's catalog (open, 2026-11-25).
    final layout = tester.takeException();
    if (layout != null) {
      expect('$layout', contains('overflowed'), reason: 'opening the page threw: $layout');
      // ignore: avoid_print
      print('LAYOUT ${c.info.id}${c.variant == null ? '' : '#${c.variant}'}: $layout');
    }
    DeviceFakeFrame.frame(c.info.id);
    return (s, DeviceTarget(s, layer.id, slot), engine);
  }

  String name(DeviceCase c) => c.variant == null ? c.info.id : '${c.info.id}#${c.variant}';

  /// Works every control on the page; the findings (empty when every control answered).
  Future<List<Finding>> work(WidgetTester tester, DeviceCase c, AppState s, DeviceTarget t, RecordingEngine engine) async {
    final findings = <Finding>[];
    final dev = name(c);
    final layer = t.layer!;
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
      if (last.$2 != index || last.$1 != layer.id || (last.$4 - value(p)).abs() > 1e-9) {
        findings.add(Finding(dev, control, gesture, 'sent ${last.$1}/${last.$2} ${last.$4}, expected ${layer.id}/$index ${value(p)}'));
        return false;
      }
      return true;
    }

    Map<String, double> snapshot() => {for (final q in t.info?.parameters ?? const <ComponentParameterInfo>[]) q.id: t.value(q.id)};
    Future<void> restore(Map<String, double> was) async {
      final now = snapshot();
      final back = {for (final e in was.entries) if (now[e.key] != e.value) e.key: e.value};
      if (back.isNotEmpty) t.setAll(back);
      await tester.pump();
    }

    Future<void> knob(Finder f, String? p, String control) async {
      final sideways = KnobDrag.sideways;
      // (gesture, step, steps, rest, frame, kind, turns it)
      final gestures = <(String, Offset, int, Duration, Duration, PointerDeviceKind, bool)>[
        // A thumb's sideways drag, slightly off horizontal (Sideways only).
        if (sideways) ('finger sideways', const Offset(5, -1.5), 12, Duration.zero, _frame, PointerDeviceKind.touch, true),
        // A quick vertical swipe is the page's under both settings.
        ('quick vertical swipe', const Offset(0, -14), 7, Duration.zero, const Duration(milliseconds: 8),
            PointerDeviceKind.touch, false),
        // A rest, then any direction: the knob's.
        ('hold then vertical', const Offset(0, -6), 10, const Duration(milliseconds: 300), _frame, PointerDeviceKind.touch, true),
        if (sideways)
          ('hold then sideways', const Offset(6, 0), 10, const Duration(milliseconds: 300), _frame, PointerDeviceKind.touch, true),
        // Held past the long-press (its menu waits for the finger to lift still), then moved.
        ('long hold then vertical', const Offset(0, -6), 10, const Duration(milliseconds: 700), _frame,
            PointerDeviceKind.touch, true),
        if (sideways)
          ('long hold then sideways', const Offset(6, 0), 10, const Duration(milliseconds: 700), _frame,
              PointerDeviceKind.touch, true),
        ('mouse drag', const Offset(0, -6), 10, Duration.zero, _frame, PointerDeviceKind.mouse, true),
      ];
      // The fallback page's Knob has no parameter key: the one it moved is the one whose value changed.
      final was = p == null ? snapshot() : null;
      for (final (gesture, step, steps, rest, frame, kind, turns) in gestures) {
        if (f.hitTestable().evaluate().isEmpty) return;
        if (p != null) {
          middle(p);
        } else {
          await restore(was!);
        }
        await tester.pump();
        final before = p == null ? null : value(p);
        engine.sent.clear();
        // A finger on the knob's face (the top of a fallback Knob, the centre of a device knob).
        final r = tester.getRect(f);
        final at = p == null ? Offset(r.center.dx, r.top + 20) : tester.getCenter(f);
        await fingerDrag(tester, at, step, steps, rest: rest, frame: frame, kind: kind);
        await tester.pumpAndSettle();
        // A long hold's lift may leave its sheet or a tooltip: close what opened.
        await _dismiss(tester);
        String? movedParam;
        if (p != null) {
          if (value(p) != before) movedParam = p;
        } else {
          movedParam = snapshot().entries.where((x) => was![x.key] != x.value).firstOrNull?.key;
        }
        if (turns && movedParam == null) {
          findings.add(Finding(dev, control, gesture, 'did not move'));
        } else if (!turns && movedParam != null) {
          findings.add(Finding(dev, control, gesture, 'turned the knob'));
        } else if (turns) {
          reached(movedParam!, gesture, control);
        }
      }
      if (was != null) await restore(was);
    }

    Future<void> slider(Finder f, String p, String control) async {
      for (final (gesture, kind, rest) in [('finger sideways', PointerDeviceKind.touch, Duration.zero),
          ('hold then sideways', PointerDeviceKind.touch, const Duration(milliseconds: 300)),
          ('mouse drag', PointerDeviceKind.mouse, Duration.zero)]) {
        final r = tester.getRect(f);
        t.set(p, t.param(p)!.min);
        await tester.pump();
        final before = value(p);
        engine.sent.clear();
        await fingerDrag(tester, Offset(r.left + r.width * 0.3, r.center.dy), const Offset(6, -1), 8, kind: kind, rest: rest);
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

    // A hero visual or an XY pad (GrabGesture, GrabPan): where it takes a finger, a drag must move something.
    Future<void> visual(Element e, String control) async {
      final w = e.widget;
      final grabs = w is GrabPan ? w.grabs : (w as GrabGesture).grabs;
      if (w is GrabGesture && w.onUpdate == null) return;
      final box = e.renderObject! as RenderBox;
      Offset? local;
      for (final fy in const [0.5, 0.3, 0.7, 0.15, 0.85]) {
        for (final fx in const [0.5, 0.3, 0.7, 0.15, 0.85]) {
          final l = Offset(box.size.width * fx, box.size.height * fy);
          if (grabs?.call(l) ?? true) {
            local = l;
            break;
          }
        }
        if (local != null) break;
      }
      if (local == null) return;
      final points = [
        box.localToGlobal(local),
        for (final fx in const [0.3, 0.7, 0.15, 0.85])
          if (grabs?.call(Offset(box.size.width * fx, box.size.height * 0.5)) ?? true)
            box.localToGlobal(Offset(box.size.width * fx, box.size.height * 0.5)),
      ];
      String? stateNow() => t.isInstrument ? null : t.layer?.components[t.slot].state;
      final gestures = <(String, Offset, int, Duration, PointerDeviceKind)>[
        ('finger sideways', const Offset(6, -1), 10, Duration.zero, PointerDeviceKind.touch),
        ('hold then vertical', const Offset(0, -6), 10, const Duration(milliseconds: 300), PointerDeviceKind.touch),
        ('hold then sideways', const Offset(6, 0), 10, const Duration(milliseconds: 300), PointerDeviceKind.touch),
        ('mouse drag', const Offset(-6, -6), 10, Duration.zero, PointerDeviceKind.mouse),
      ];
      final was = snapshot();
      final wasState = stateNow();
      final movedBy = <String>{};
      for (final (gesture, step, steps, rest, kind) in gestures) {
        var moved = false;
        // One way, then the other (a value at the end of its travel moves only back), at a few places (a hero
        // whose handles are its crossovers takes a drag only near one).
        search:
        for (final at in points) {
          for (final dir in const [1.0, -1.0]) {
            await restore(was);
            engine.sent.clear();
            await fingerDrag(tester, at, step * dir, steps, rest: rest, kind: kind);
            await tester.pumpAndSettle();
            await _dismiss(tester);
            final now = snapshot();
            if (now.entries.any((x) => was[x.key] != x.value)) {
              moved = true;
              final p = now.entries.firstWhere((x) => was[x.key] != x.value).key;
              reached(p, gesture, control);
              break search;
            }
            if (stateNow() != wasState) {  // a painted state (Molt's spectrum), written to the engine
              moved = true;
              break search;
            }
          }
        }
        if (moved) movedBy.add(gesture);
      }
      await restore(was);
      // A visual uses the axes it has (a wavetable's up and down only with a warp on): a rested drag moves it, a quick
      // sideways one too where a rested sideways one does, and the mouse.
      if (!movedBy.contains('hold then vertical') && !movedBy.contains('hold then sideways')) {
        findings.add(Finding(dev, control, 'hold then drag', 'moved nothing'));
      }
      if (movedBy.contains('hold then sideways') && !movedBy.contains('finger sideways')) {
        findings.add(Finding(dev, control, 'finger sideways', 'moved nothing'));
      }
      if (!movedBy.contains('mouse drag')) findings.add(Finding(dev, control, 'mouse drag', 'moved nothing'));
    }

    // On a swipe panel: a quick sideways swipe that starts beside a knob's face (its label) changes the panel.
    Future<void> swipeBeside(PageController pc) async {
      final knobs = find.byType(DeviceKnob).hitTestable().evaluate()
          .where((e) => tester.getRect(find.byWidget(e.widget)).bottom < phone.height - 120).toList();
      if (knobs.isEmpty) return;
      final r = tester.getRect(find.byWidget(knobs.first.widget));
      final page = pc.page!.round();
      final last = (find.byType(PageView).evaluate().first.widget as PageView).childrenDelegate.estimatedChildCount! - 1;
      final dir = page < last ? -1.0 : 1.0;
      await fingerDrag(tester, Offset(r.center.dx, r.bottom - 4), Offset(28 * dir, 0), 10,
          frame: const Duration(milliseconds: 8));
      await tester.pumpAndSettle();
      if (pc.page!.round() == page) {
        findings.add(Finding(dev, 'panel ${page + 1}', 'swipe from a knob\'s label', 'did not change the panel'));
      }
      pc.jumpToPage(page);
      await tester.pumpAndSettle();
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
          if (pv.controller != null) await swipeBeside(pv.controller!);
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
          final visuals = <(Element, String)>[];
          for (final e in find.byWidgetPredicate((w) => w is GrabPan || w is GrabGesture).hitTestable().evaluate()) {
            final box = e.renderObject as RenderBox?;
            if (box == null || !box.hasSize) continue;
            final r = box.localToGlobal(Offset.zero) & box.size;
            if (!screen.deflate(4).contains(r.topLeft) || !screen.deflate(4).contains(r.bottomRight)) continue;
            final id = 'visual ${e.widget.runtimeType} ${e.widget.key ?? ''} $ti/$pi/${(r.top + (pos?.pixels ?? 0)).round()}';
            if (done.add(id)) visuals.add((e, id));
          }
          for (final (e, id) in visuals) {
            if (!e.mounted) continue;
            await visual(e, id);
          }
          // The fallback page's knobs (arrange/knob.dart), by their label.
          final plain = <(Finder, String)>[];
          for (final e in find.byType(Knob).hitTestable().evaluate()) {
            final box = e.renderObject as RenderBox?;
            if (box == null || !box.hasSize) continue;
            final r = box.localToGlobal(Offset.zero) & box.size;
            if (!screen.deflate(4).contains(r.topLeft) || !screen.deflate(4).contains(r.bottomRight)) continue;
            final label = (e.widget as Knob).label;
            final id = 'knob $label $ti/$pi';
            if (done.add(id)) plain.add((find.byWidget(e.widget), id));
          }
          for (final (f, id) in plain) {
            if (f.evaluate().isEmpty) continue;
            await knob(f, null, id);
          }
          for (final (key, c) in candidates) {
            if (find.byKey(key).evaluate().isEmpty) continue;  // a visual's drag rebuilt the page without it
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
  // A device the library offers must play where it goes: a MIDI effect on an effect chain is left out by the engine.
  testWidgets('the library offers no MIDI effect for a chain', (tester) async {
    final s = AppState(settings: Settings());
    s.nativeCatalog = [
      ..._catalog,
      const NativeComponentInfo(id: 'org.caw.midi.test', name: 'Arp', role: 'event_processor', ports: [], parameters: []),
    ];
    expect(s.builtinAssets.where((a) => a.native?.role == 'event_processor'), isEmpty);
    expect(s.builtinAssets.where((a) => a.native?.id == 'org.caw.drive'), isNotEmpty);
    s.dispose();
  });

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

  // Settings › Knobs turn with › Up and down: a quick swipe still scrolls, a rest then any drag turns the knob.
  group('with knobs set to turn up and down', () {
    for (final c in cases.where((c) => const {'org.caw.drive#0', 'org.caw.reverb#0', 'org.caw.synth.flagship',
        'org.caw.timber'}.contains(name(c)))) {
      testWidgets(name(c), (tester) async {
        final (s, t, engine) = await open(tester, c, sideways: false);
        final findings = await work(tester, c, s, t, engine);
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
