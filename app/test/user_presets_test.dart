// User presets: the library on disk (save, load, rename, duplicate, delete, favourites), untrusted-file limits, the
// header's label with "*", undo of a load, track presets onto a track and onto the empty area, export and import, the
// save flow and quick save in the editor, and a golden of the preset browser on a phone.
import 'dart:convert';
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/files_catalog.dart';
import 'package:caw/model/user_presets.dart';
import 'package:caw/ui/devices/kit/preset_actions.dart';
import 'package:caw/ui/devices/kit/presets.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

const comp = 'org.caw.compressor';
const flagship = 'org.caw.synth.flagship';

UserPreset devicePreset(String id, String name, Map<String, double> params, {String category = '', String? state}) =>
    UserPreset(id: id, kind: UserPresetKind.device, name: name, category: category,
        device: PresetDevice(comp, params, state: state), modified: DateTime.utc(2026, 11, 10));

void main() {
  late Directory tmp;
  final states = <AppState>[];
  var motion = MotionLevel.full;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('caw_presets_');
    motion = Motion.setting;
  });
  tearDown(() {
    for (final s in states) {
      s.dispose();
    }
    states.clear();
    Motion.setting = motion;
    tmp.deleteSync(recursive: true);
  });

  AppState state(String id) {
    final s = stateWith(id);
    Motion.setting = MotionLevel.off;
    states.add(s);
    return s;
  }

  group('the library on disk', () {
    test('save, load, rename, duplicate, delete and favourites survive a restart', () async {
      final a = UserPresetStore(tmp);
      await a.load();
      a.put(devicePreset('up_1', 'Glue', {'ratio': 2}, category: 'Bus', state: 'AAEC'));
      a.put(devicePreset('up_2', 'Smash', {'ratio': 20}));
      a.setFavourite('user:up_2', true);
      a.setFavourite('factory:$comp/Init', true);
      await a.flush();

      var b = UserPresetStore(tmp);
      await b.load();
      expect(b.forComponent(comp).map((p) => p.name), ['Glue', 'Smash']);
      final glue = b.byId('up_1')!;
      expect(glue.category, 'Bus');
      expect(glue.device!.params, {'ratio': 2});
      expect(glue.device!.state, 'AAEC');
      expect(b.isFavourite('user:up_2'), isTrue);
      expect(b.isFavourite('factory:$comp/Init'), isTrue);

      b.rename('up_1', 'Gentle glue', category: 'Mix');
      final copy = b.duplicate('up_2')!;
      expect(copy.name, 'Smash copy');
      expect(b.duplicate('up_2')!.name, 'Smash copy 2');
      b.remove('up_2');
      await b.flush();

      b = UserPresetStore(tmp);
      await b.load();
      expect(b.all.map((p) => p.name), ['Gentle glue', 'Smash copy', 'Smash copy 2']);
      expect(b.byId('up_1')!.category, 'Mix');
      expect(b.isFavourite('user:up_2'), isFalse, reason: 'a deleted preset leaves the favourites');
      expect(tmp.listSync().whereType<File>().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('free names count up from 1, ignoring case', () {
      final s = UserPresetStore(null);
      expect(s.freeName('Pad', UserPresetKind.device, componentId: comp), 'Pad 1');
      s.put(devicePreset('up_1', 'pad 1', {}));
      expect(s.freeName('Pad', UserPresetKind.device, componentId: comp), 'Pad 2');
      expect(s.freeName('Pad', UserPresetKind.track), 'Pad 1', reason: 'track presets are their own names');
      expect(s.named(UserPresetKind.device, 'PAD 1', componentId: comp)?.id, 'up_1');
    });
  });

  group('untrusted files', () {
    String file(Map<String, Object?> j) => jsonEncode({'format': 'caw.preset', 'version': 1, ...j});

    test('a file that is too large, not JSON, another format or a newer version is refused', () {
      final big = file({'kind': 'device', 'name': 'x', 'device': {'component': comp}, 'pad': 'a' * PresetLimits.fileBytes});
      expect(UserPreset.decode(big, id: 'i'), isNull);
      expect(UserPreset.decode('{nope', id: 'i'), isNull);
      expect(UserPreset.decode('[1,2]', id: 'i'), isNull);
      expect(UserPreset.decode(jsonEncode({'format': 'other', 'version': 1}), id: 'i'), isNull);
      expect(UserPreset.decode(file({'version': 2, 'kind': 'device', 'name': 'x', 'device': {'component': comp}}), id: 'i'),
          isNull);
      expect(UserPreset.decode(file({'kind': 'device', 'name': '  ', 'device': {'component': comp}}), id: 'i'), isNull);
      expect(UserPreset.decode(file({'kind': 'device', 'name': 'x', 'device': {'component': '../../etc'}}), id: 'i'), isNull);
      expect(UserPreset.decode(file({'kind': 'track', 'name': 'x'}), id: 'i'), isNull, reason: 'nothing to load');
      expect(UserPreset.decode(file({'kind': 'macro', 'name': 'x'}), id: 'i'), isNull);
    });

    test('wrong types are dropped and every text is bounded', () {
      final p = UserPreset.decode(file({
        'kind': 'device',
        'name': 'Na\u0000me/${'n' * 200}',
        'category': 7,
        'device': {
          'component': comp,
          'descriptor_version': 'one',
          'params': {'ratio': 3, 'knee': 'loud', 'attack': true, 'x' * 100: 1, for (var i = 0; i < 2000; i++) 'p$i': i},
          'state': 'not base64!',
          'state_version': -4,
          'bypass': 'yes',
        },
      }), id: 'i')!;
      expect(p.name, startsWith('Name'));
      expect(p.name.length, lessThanOrEqualTo(PresetLimits.name));
      expect(p.category, '');
      final d = p.device!;
      expect(d.params['ratio'], 3);
      expect(d.params.containsKey('knee'), isFalse);
      expect(d.params.containsKey('attack'), isFalse);
      expect(d.params.length, lessThanOrEqualTo(PresetLimits.params));
      expect(d.state, isNull);
      expect((d.descriptorVersion, d.stateVersion, d.bypass), (1, 1, false));
      final track = UserPreset.decode(file({
        'kind': 'track', 'name': 't',
        'effects': [for (var i = 0; i < 200; i++) {'component': comp}, 'junk', 5],
      }), id: 'i')!;
      expect(track.effects.length, PresetLimits.effects);
    });

    test('the library skips damaged and oversized files and odd file names', () async {
      File('${tmp.path}/up_ok.json').writeAsStringSync(devicePreset('up_ok', 'Ok', {'ratio': 2}).encode());
      File('${tmp.path}/up_bad.json').writeAsStringSync('{"format": "caw.preset", "version": 1, "kind"');
      File('${tmp.path}/up_big.json').writeAsStringSync(' ' * (PresetLimits.fileBytes + 1));
      File('${tmp.path}/odd name.json').writeAsStringSync(devicePreset('x', 'Odd', {}).encode());
      final s = UserPresetStore(tmp);
      await s.load();
      expect(s.all.map((p) => p.name), ['Ok']);
      expect(() => s.put(devicePreset('../evil', 'Evil', {})), throwsArgumentError);
    });
  });

  group('device presets', () {
    test('the label names a user preset, with "*" once changed; a rename shows', () {
      final s = state(comp);
      final t = targetOf(s, comp);
      t.set('ratio', 8);
      expect(DevicePresets.label(t), 'Custom');
      final p = UserPreset(id: 'up_1', kind: UserPresetKind.device, name: 'Glue', device: s.captureDevice(t)!,
          modified: DateTime.now());
      s.userPresets.put(p);
      DevicePresets.remember(t, DevicePreset.user(p));
      expect(DevicePresets.label(t), 'Glue');
      expect(DevicePresets.currentUser(t)?.id, 'up_1');
      t.set('ratio', 9);
      expect(DevicePresets.label(t), 'Glue *');
      expect(DevicePresets.modified(t), isTrue);
      s.userPresets.rename('up_1', 'Bus glue');
      expect(DevicePresets.label(t), 'Bus glue *');
      DevicePresets.apply(t, DevicePresets.of(t).firstWhere((x) => x.isUser));
      expect(t.value('ratio'), 8);
      expect(DevicePresets.label(t), 'Bus glue');
      s.userPresets.remove('up_1');
      expect(DevicePresets.label(t), 'Bus glue', reason: 'a deleted preset still names what was loaded');
      expect(DevicePresets.currentUser(t), isNull);
    });

    test('the browser lists Factory then the user\'s; unknown parameters are ignored, missing ones default', () {
      final s = state(comp);
      final t = targetOf(s, comp);
      s.userPresets.put(devicePreset('up_1', 'Odd', {'ratio': 6, 'no_such_knob': 3}));
      final all = DevicePresets.of(t);
      expect(all.first.name, 'Init');
      expect(all.last.name, 'Odd');
      t.set('knee', 12);
      DevicePresets.apply(t, all.last);
      expect(t.value('ratio'), 6);
      expect(t.value('knee'), 6, reason: 'left out of the preset: its default');
      expect(t.use!.params.containsKey('no_such_knob'), isFalse);
    });

    test('loading a preset is one undo step, its saved state included', () {
      final s = state(comp);
      s.starting = false;
      final t = targetOf(s, comp);
      t.set('ratio', 3);
      s.endUndoStep();
      DevicePresets.apply(t, DevicePreset.user(devicePreset('up_1', 'Glue', {'ratio': 10}, state: 'AAEC')));
      expect((t.value('ratio'), t.use!.state), (10, 'AAEC'));
      expect(s.undo(), isTrue);
      expect(t.value('ratio'), 3);
      expect(t.use!.state, isNull);
    });
  });

  group('track presets', () {
    UserPreset capture(AppState s) {
      final layer = s.project.layers.first;
      DeviceTarget(s, 'a', DeviceTarget.instrumentSlot).set('osc1_level', 0.3);
      s.addNativeEffect(layer, comp);
      DeviceTarget(s, 'a', 0).set('ratio', 7);
      final p = s.captureTrack(layer, name: 'Lead chain')!;
      s.userPresets.put(p);
      return p;
    }

    test('saved from a track, it loads onto another one as one undo step', () {
      final s = state(flagship);
      final p = capture(s);
      expect(p.instrument!.componentId, flagship);
      expect(p.effects.single.params['ratio'], 7);
      s.starting = false;
      final other = s.addEmptyTrack(name: 'B');
      s.addNativeEffect(other, 'org.caw.reverb.pro');
      s.endUndoStep();
      expect(s.applyTrackPreset(other, p), isTrue);
      expect(other.instrument!.id, flagship);
      expect(other.instrument!.params['osc1_level'], 0.3);
      expect(other.components.map((c) => c.id), [comp], reason: 'the chain replaces the native effects');
      s.endUndoStep();
      expect(s.undo(), isTrue);
      final back = s.project.layers.firstWhere((l) => l.name == 'B');
      expect(back.instrument, isNull);
      expect(back.components.map((c) => c.id), ['org.caw.reverb.pro']);
    });

    test('dropped on the empty area it makes a track; a device preset joins a track\'s chain', () {
      final s = state(flagship);
      final p = capture(s);
      final made = s.dropOnNewTrack(AssetDrag(AssetKind.trackPreset, p.id, p.name))!;
      expect(made.name, 'Lead chain');
      expect(made.instrument!.id, flagship);
      expect(made.components.single.params['ratio'], 7);
      final d = devicePreset('up_d', 'Squash', {'ratio': 12});
      s.userPresets.put(d);
      final drag = AssetDrag(AssetKind.devicePreset, d.id, d.name);
      expect(s.replacesInstrument(made, drag), isFalse, reason: 'an effect preset replaces nothing');
      expect(s.dropAsset(made, drag), isTrue);
      expect(made.components.last.params['ratio'], 12);
      expect(s.replacesInstrument(made, AssetDrag(AssetKind.trackPreset, p.id, p.name)), isTrue);
      expect(s.dropAsset(made, const AssetDrag(AssetKind.trackPreset, 'gone', 'Gone')), isFalse);
    });

    test('Files lists them under Presets, renames, duplicates and deletes them', () {
      final s = state(flagship);
      final p = capture(s);
      s.userPresets.put(devicePreset('up_d', 'Squash', {'ratio': 12}));
      final folder = s.folderAt('presets')!;
      final assets = s.folderAssets(folder);
      expect(assets.map((a) => (a.name, a.type)),
          [('Lead chain', FileAssetType.trackPreset), ('Squash', FileAssetType.devicePreset)]);
      expect(assets.first.drag?.kind, AssetKind.trackPreset);
      expect(s.searchAssets('squash', {}).single.preset?.id, 'up_d');
      s.renameAsset(assets.first, 'Lead 2');
      expect(s.userPresets.byId(p.id)!.name, 'Lead 2');
      expect(s.duplicateAsset(assets.last), startsWith('preset:'));
      s.deleteAsset(assets.last);
      expect(s.userPresets.byId('up_d'), isNull);
    });
  });

  group('the editor', () {
    Future<AppState> open(WidgetTester tester, String id) async {
      final s = state(id);
      late BuildContext ctx;
      await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      })), goldenSizes['phone']!);
      openDevice(ctx, s, id);
      await tester.pumpAndSettle();
      return s;
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }

    testWidgets('Save preset… names it "Compressor 1", asks before replacing, and quick save saves over it',
        (tester) async {
      final s = await open(tester, comp);
      final t = targetOf(s, comp);
      t.set('ratio', 5);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('device-presets')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('preset-mine-empty')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('preset-save')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byKey(const ValueKey('preset-save-name')));
      expect(field.controller!.text, '${t.label} 1');
      await tester.enterText(find.byKey(const ValueKey('preset-save-tag')), 'Bus');
      await tester.tap(find.byKey(const ValueKey('preset-save-ok')));
      await tester.pumpAndSettle();
      final saved = s.userPresets.forComponent(comp).single;
      expect((saved.name, saved.category, saved.device!.params['ratio']), ('${t.label} 1', 'Bus', 5));
      expect(find.text('Saved "${saved.name}"'), findsOneWidget, reason: 'the toast');
      expect(find.byKey(ValueKey('preset-user-${saved.name}')), findsOneWidget);

      // The same name again: asked first.
      t.set('ratio', 6);
      await tester.tap(find.byKey(const ValueKey('preset-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('preset-save-ok')));
      await tester.pumpAndSettle();
      expect(find.text('Replace the preset?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('preset-replace')));
      await tester.pumpAndSettle();
      expect(s.userPresets.forComponent(comp).single.device!.params['ratio'], 6);
      // Undo in the toast brings the old one back.
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(s.userPresets.forComponent(comp).single.device!.params['ratio'], 5);

      await tester.tapAt(const Offset(200, 40));  // closes the sheet
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('device-preset-quicksave')), findsOneWidget, reason: '6 ≠ the saved 5');
      expect(find.text('${saved.name} *'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('device-preset-quicksave')));
      await tester.pumpAndSettle();
      expect(s.userPresets.forComponent(comp).single.device!.params['ratio'], 6);
      expect(find.text(saved.name), findsOneWidget);
      expect(find.byKey(const ValueKey('device-preset-quicksave')), findsNothing);

      // Ctrl+S saves over it from the keyboard.
      t.set('ratio', 7);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(s.userPresets.forComponent(comp).single.device!.params['ratio'], 7);
      await close(tester);
    });

    testWidgets('long-press deletes a preset, with Undo; favourites and search narrow the list', (tester) async {
      final s = await open(tester, comp);
      s.userPresets.put(devicePreset('up_1', 'Glue', {'ratio': 2}, category: 'Bus'));
      s.userPresets.put(devicePreset('up_2', 'Smash', {'ratio': 20}));
      await tester.tap(find.byKey(const ValueKey('device-presets')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('preset-fav-user:up_2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('preset-filter-Favourites')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('preset-user-Smash')), findsOneWidget);
      expect(find.byKey(const ValueKey('preset-user-Glue')), findsNothing);
      expect(find.byKey(const ValueKey('preset-Init')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('preset-filter-Favourites')));
      await tester.enterText(find.byKey(const ValueKey('preset-search')), 'bus');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('preset-user-Glue')), findsOneWidget, reason: 'its tag matches');
      expect(find.byKey(const ValueKey('preset-user-Smash')), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('preset-user-Glue')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(s.userPresets.byId('up_1'), isNull);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(s.userPresets.byId('up_1')?.name, 'Glue');
      await close(tester);
    });

    testWidgets('export and import round trip; an oversized or foreign file is refused', (tester) async {
      final s = await open(tester, comp);
      final p = devicePreset('up_1', 'Glue', {'ratio': 2.5}, category: 'Bus', state: 'AAEC');
      s.userPresets.put(p);
      String? name;
      List<int>? bytes;
      PresetFiles.save = (n, b) async {
        name = n;
        bytes = b;
        return true;
      };
      addTearDown(() {
        PresetFiles.save = (_, _) async => false;
        PresetFiles.pick = () async => null;
      });
      final ctx = tester.element(find.byKey(const ValueKey('device-editor')));
      await exportPreset(ctx, p);
      expect(name, 'Glue.cawpreset');
      PresetFiles.pick = () async => (name: name!, length: bytes!.length, read: () async => utf8.decode(bytes!));
      final back = (await importPreset(ctx, s.userPresets))!;
      expect(back.id, isNot(p.id));
      expect(back.name, 'Glue 2', reason: 'the name was taken');
      expect((back.category, back.device!.state), ('Bus', 'AAEC'));
      expect(back.device!.params, {'ratio': 2.5});

      PresetFiles.pick = () async => (name: 'big', length: PresetLimits.fileBytes + 1, read: () async => fail('read'));
      expect(await importPreset(ctx, s.userPresets), isNull);
      PresetFiles.pick = () async => (name: 'x', length: 10, read: () async => '{"caw_app_project": 1}');
      expect(await importPreset(ctx, s.userPresets), isNull);
      await tester.pump();
      expect(find.textContaining('Not imported'), findsOneWidget);
      expect(s.userPresets.all, hasLength(2));
      await close(tester);
    });

    testWidgets('golden: the preset browser on a phone', (tester) async {
      final s = await open(tester, comp);
      s.userPresets
        ..put(devicePreset('up_1', 'Bus glue', {'ratio': 2}, category: 'Bus'))
        ..put(devicePreset('up_2', 'Drum smash', {'ratio': 20}, category: 'Drums'))
        ..put(devicePreset('up_3', 'Vocal level', {'ratio': 3}))
        ..setFavourite('user:up_2', true);
      final t = targetOf(s, comp);
      DevicePresets.apply(t, DevicePreset.user(s.userPresets.byId('up_1')!));
      t.set('ratio', 2.5);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('device-presets')));
      await tester.pumpAndSettle();
      await expectLater(goldenScreen, matchesGoldenFile('goldens/preset_browser_phone.png'));
      await close(tester);
    });
  });
}
