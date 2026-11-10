// The Files browser (Unity-style Project window) and the asset picker: select vs open, search and filters, the portrait drawer, menus.
import 'dart:io';

import 'package:caw/engine/component_info.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/files_catalog.dart';
import 'package:caw/model/project.dart';
import 'package:caw/ui/file_manager_screen.dart';
import 'package:caw/ui/files/asset_picker.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AppState _state() {
  final s = AppState();
  final cpp = CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz');
  s.project = ProjectDoc(id: 'files-test', name: 'Files test', modules: [
    ModuleDoc(id: 'crush', name: 'Crush', source: '---\nkind: effect\n---\nx'),
    ModuleDoc(id: 'bass', name: 'Bass', source: '---\nkind: generator\n---\nsin(110)'),
    ModuleDoc(id: 'beat', name: 'Beat', source: '---\nkind: pattern\n---\nc4'),
  ], layers: [
    LayerDoc(id: 'l1', name: 'Bass track', color: 0, generatorId: 'bass', effectIds: ['crush'], patternId: 'beat'),
  ], cppComponents: [cpp]);
  s.info['crush'] = const ModuleInfo(ok: true, kind: 'effect');
  s.info['bass'] = const ModuleInfo(ok: true, kind: 'generator');
  s.info['beat'] = const ModuleInfo(ok: true, kind: 'pattern');
  s.nativeCatalog = const [
    NativeComponentInfo(id: 'org.caw.gain', name: 'Gain', role: 'effect', builtin: true),
    NativeComponentInfo(id: 'org.caw.width', name: 'Stereo width', role: 'effect', builtin: true),
  ];
  return s;
}

Future<SectionController> _pump(WidgetTester tester, AppState s, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final sections = SectionController();
  await tester.pumpWidget(MaterialApp(
    home: SectionScope(controller: sections, child: Scaffold(body: FileManagerScreen(state: s, onOpenBuilder: () {}))),
  ));
  await tester.pump();
  return sections;
}

void main() {
  testWidgets('tap selects and shows the inspector; double-tap opens in Build', (tester) async {
    final s = _state();
    final sections = await _pump(tester, s, const Size(1200, 800));
    expect(find.text('Effects & instruments'), findsWidgets); // the tree, in landscape
    await tester.tap(find.text('My C++ effects').first);
    await tester.pump();

    final fuzz = find.byKey(const ValueKey('cpp:cpp1'));
    expect(fuzz, findsOneWidget);
    await tester.tap(fuzz);
    await tester.pump();
    expect(find.text('C++ effect'), findsOneWidget); // the inspector's type line
    expect(find.text('Not built'), findsOneWidget);
    expect(find.text('Not used on any track'), findsOneWidget);
    expect(sections.current, Section.arrange);
    expect(sections.buildTabs, isEmpty);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(fuzz);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(fuzz);
    await tester.pump();
    final cpp = s.project.cppComponents.single;
    expect(sections.current, Section.build);
    expect(sections.activeBuildTab, BuildTab(BuildTabKind.cpp, cpp.componentId));

    // A .caw module opens in a .caw tab, and its inspector says where it is used.
    sections.show(Section.files);
    await tester.tap(find.text('.caw modules').first);
    await tester.pump();
    final crush = find.byKey(const ValueKey('mod:crush'));
    await tester.tap(crush);
    await tester.pump();
    expect(find.text('Used on Bass track'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(crush);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(crush);
    await tester.pump();
    expect(sections.activeBuildTab, const BuildTab(BuildTabKind.caw, 'crush'));
    expect(s.selectedModuleId, 'crush');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('search looks through every folder and the type filters narrow it', (tester) async {
    final s = _state();
    await _pump(tester, s, const Size(1200, 800));
    await tester.enterText(find.byType(TextField), 'b');
    await tester.pump();
    expect(find.byKey(const ValueKey('mod:bass')), findsOneWidget);
    expect(find.byKey(const ValueKey('mod:beat')), findsOneWidget);
    expect(find.byKey(const ValueKey('mod:crush')), findsNothing);
    expect(find.text('Search'), findsOneWidget); // the breadcrumb

    await tester.tap(find.byTooltip('Patterns'));
    await tester.pump();
    expect(find.byKey(const ValueKey('mod:beat')), findsOneWidget);
    expect(find.byKey(const ValueKey('mod:bass')), findsNothing);

    // A filter without a query narrows the open folder.
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    await tester.tap(find.byTooltip('Patterns'));
    await tester.tap(find.byTooltip('Effects'));
    await tester.tap(find.text('.caw modules').first);
    await tester.pump();
    expect(find.byKey(const ValueKey('mod:crush')), findsOneWidget);
    expect(find.byKey(const ValueKey('mod:bass')), findsNothing);
  });

  testWidgets('in portrait the tree is a drawer and the breadcrumb leads', (tester) async {
    final s = _state();
    await _pump(tester, s, const Size(400, 800));
    expect(find.text('Favourites'), findsNothing); // no tree on screen
    expect(find.text('Effects & instruments'), findsOneWidget); // the breadcrumb
    await tester.tap(find.byTooltip('Folders'));
    await tester.pumpAndSettle();
    expect(find.text('FOLDERS'), findsOneWidget);
    await tester.tap(find.text('Patterns'));
    await tester.pumpAndSettle();
    expect(find.text('FOLDERS'), findsNothing); // the drawer closed
    expect(find.text('Audio & MIDI'), findsOneWidget); // breadcrumb: Audio & MIDI > Patterns
    expect(find.byKey(const ValueKey('mod:beat')), findsOneWidget);

    // Selecting shows the compact inspector at the bottom, with ▶ preview for a pattern.
    await tester.tap(find.byKey(const ValueKey('mod:beat')));
    await tester.pump();
    expect(find.text('Used on Bass track'), findsOneWidget);
    await tester.tap(find.byTooltip('Preview'));
    await tester.pump();
    expect(s.previewOnly, isTrue);
    expect(s.selectedModuleId, 'beat');
    await tester.tap(find.byTooltip('Stop preview'));
    await tester.pump();
    expect(s.previewOnly, isFalse);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the size slider at its smallest shows a list', (tester) async {
    final s = _state();
    await _pump(tester, s, const Size(1200, 800));
    await tester.tap(find.text('.caw modules').first);
    await tester.pump();
    final slider = find.byType(Slider);
    await tester.drag(slider, const Offset(-200, 0));
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, 0);
    expect(find.text('FX'), findsWidgets); // list rows show the type badge next to the name
    expect(tester.getSize(find.byKey(const ValueKey('mod:crush'))).height, 34);
  });

  testWidgets('the asset picker lists Built-in and My effects and returns the one tapped', (tester) async {
    final s = _state();
    AssetDrag? picked;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
      onPressed: () async => picked = await showAssetPicker(context, s, kinds: {AssetKind.nativeEffect, AssetKind.cawModule}),
      child: const Text('open'),
    )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Add effect'), findsOneWidget);
    expect(find.text('BUILT-IN'), findsOneWidget);
    expect(find.text('MY EFFECTS'), findsOneWidget);
    expect(find.text('Fuzz'), findsOneWidget);
    expect(find.text('Not built'), findsOneWidget); // listed with a badge before it is built
    expect(find.text('Crush'), findsOneWidget);
    expect(find.text('Beat'), findsNothing); // patterns weren't asked for

    await tester.enterText(find.byType(TextField), 'gai');
    await tester.pump();
    expect(find.text('Stereo width'), findsNothing);
    await tester.tap(find.text('Gain'));
    await tester.pumpAndSettle();
    expect(picked?.kind, AssetKind.nativeEffect);
    expect(picked?.id, 'org.caw.gain');
    expect(picked?.name, 'Gain');
  });

  testWidgets('"New C++ effect" on a folder adds the blank effect and opens it in Build', (tester) async {
    final s = _state();
    final sections = await _pump(tester, s, const Size(1200, 800));
    await tester.longPress(find.text('Effects & instruments').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New C++ effect'));
    await tester.pumpAndSettle();
    expect(s.project.cppComponents, hasLength(2));
    final added = s.project.cppComponents.last;
    expect(added.name, 'New effect');
    expect(added.files.keys, contains('src/effect.cpp'));
    expect(sections.current, Section.build);
    expect(sections.activeBuildTab, BuildTab(BuildTabKind.cpp, added.componentId));
  });

  testWidgets('long-press menu: favourite, duplicate, and delete warns when used on tracks', (tester) async {
    final s = _state();
    await _pump(tester, s, const Size(1200, 800));
    await tester.tap(find.text('.caw modules').first);
    await tester.pump();

    await tester.longPress(find.byKey(const ValueKey('mod:crush')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to Favourites'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Favourites').first);
    await tester.pump();
    expect(find.byKey(const ValueKey('mod:crush')), findsOneWidget);
    expect(find.byKey(const ValueKey('mod:bass')), findsNothing);

    await tester.longPress(find.byKey(const ValueKey('mod:crush')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    expect(s.project.modules.where((m) => m.name == 'Crush copy'), hasLength(1));

    await tester.longPress(find.byKey(const ValueKey('mod:crush')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Used on Bass track'), findsWidgets);
    await tester.tap(find.text('Delete anyway'));
    await tester.pumpAndSettle();
    expect(s.project.module('crush'), isNull);
    expect(s.project.layers.single.effectIds, isEmpty);
    await tester.pump(const Duration(seconds: 3)); // the snack bar
  });

  testWidgets('assets drag as AssetDrag: effects by component id, modules and patterns by module id', (tester) async {
    final s = _state();
    await _pump(tester, s, const Size(1200, 800));
    await tester.tap(find.text('Built-in').first);
    await tester.pump();
    final gain = tester.widget<LongPressDraggable<AssetDrag>>(find.descendant(
        of: find.byKey(const ValueKey('native:org.caw.gain')), matching: find.byType(LongPressDraggable<AssetDrag>)));
    expect(gain.data?.kind, AssetKind.nativeEffect);
    expect(gain.data?.id, 'org.caw.gain');
    expect(s.folderAssets(s.folderAt('audio/patterns')!).single.drag?.kind, AssetKind.pattern);
    expect(s.cppAssets.single.drag?.id, s.project.cppComponents.single.componentId);
  });

  test('the catalogue: uses, duplicate of a C++ effect gets its own id, deleting it removes its uses', () {
    final s = _state();
    final cpp = s.project.cppComponents.single;
    s.project.layers.single.components.add(ComponentUseDoc(cpp.componentId));
    final asset = s.cppAssets.single;
    expect(s.usesOf(asset), ['Bass track']);
    final key = s.duplicateAsset(asset)!;
    final copy = s.assetByKey(key)!.cpp!;
    expect(copy.componentId, isNot(cpp.componentId));
    expect(copy.files['src/effect.cpp'], contains(copy.componentId));
    expect(copy.files['src/effect.cpp'], isNot(contains(cpp.componentId)));
    s.deleteAsset(asset);
    expect(s.project.cppComponents, [copy]);
    expect(s.project.layers.single.components, isEmpty);
  });

  test('with the engine, Built-in lists the engine\'s own effects as draggable native effects (needs CAW_LIB)', () async {
    final s = AppState();
    s.engine = Engine.create();
    addTearDown(s.dispose);
    final list = await s.refreshNativeCatalog();
    expect(list.where((c) => c.builtin), isNotEmpty);
    final builtins = s.builtinAssets;
    expect(builtins, isNotEmpty);
    expect(builtins.every((a) => a.drag == null || a.drag!.kind == AssetKind.nativeEffect), isTrue);
  }, skip: (Platform.environment['CAW_LIB'] ?? '').isEmpty);
}
