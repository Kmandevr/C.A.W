// Layout fit: every main screen and sheet at a 360 dp phone, a phone with large text (1.3) and a tablet, with the
// system bars' safe area, must lay out without overflow or other layout errors. FIT_SHOTS=<dir> also runs a 384 dp
// phone, a desktop and the light theme, and writes screenshots and a report (truncated text, small tap targets).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:caw/engine/engine.dart';
import 'package:caw/engine/stress.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/background_playback.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/music_video.dart';
import 'package:caw/model/music_video_edit.dart';
import 'package:caw/model/music_video_overlay.dart';
import 'package:caw/model/music_video_director.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/startup_progress.dart';
import 'package:caw/model/storage.dart';
import 'package:caw/model/stress_runner.dart';
import 'package:caw/model/telemetry/device_probe.dart';
import 'package:caw/model/telemetry/relay_client.dart';
import 'package:caw/model/telemetry/telemetry.dart';
import 'package:caw/model/telemetry/telemetry_config.dart';
import 'package:caw/model/updates/releases.dart' hide AssetKind;
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/updates/update_fetch.dart';
import 'package:caw/model/updates/update_service.dart';
import 'package:caw/ui/arrange/mixer_card.dart';
import 'package:caw/ui/benchmark/benchmark_screen.dart';
import 'package:caw/ui/background_playback_ui.dart';
import 'package:caw/ui/export_page.dart';
import 'package:caw/ui/file_manager_screen.dart';
import 'package:caw/ui/files/asset_picker.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/music_video/video_editor_page.dart';
import 'package:caw/ui/music_video/video_setup_sheet.dart';
import 'package:caw/ui/music_video/video_painter.dart';
import 'package:caw/ui/privacy/feedback_sheet.dart';
import 'package:caw/ui/privacy/privacy_pages.dart';
import 'package:caw/ui/settings/settings_page.dart';
import 'package:caw/ui/settings/settings_registry.dart';
import 'package:caw/ui/settings/settings_deps.dart';
import 'package:caw/ui/settings/privacy_settings.dart';
import 'package:caw/ui/shell.dart';
import 'package:caw/ui/startup_screen.dart';
import 'package:caw/ui/theme.dart';
import 'package:caw/ui/updates/update_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'background_playback_test.dart' show FakePlaybackService;
import 'audio_fake.dart';
import 'benchmark_test.dart' show FakeStress;
import 'device_ui_fixture.dart';
import 'golden_util.dart';
import 'music_video_test_song.dart';
import 'updates_test.dart' show FakeTransport, FakeInstaller, ListSource, sample;

class _Size {
  const _Size(this.name, this.size, this.scale, this.pad);
  final String name;
  final Size size;
  final double scale;
  final EdgeInsets pad;
  bool get phone => size.width < 600;
}

const _sizes = [
  _Size('p360', Size(360, 800), 1, EdgeInsets.only(top: 28, bottom: 48)),
  _Size('s22', Size(384, 854), 1, EdgeInsets.only(top: 32, bottom: 16)),
  _Size('p412x13', Size(412, 915), 1.3, EdgeInsets.only(top: 32, bottom: 24)),
  _Size('tablet', Size(800, 1280), 1, EdgeInsets.only(top: 24, bottom: 24)),
  _Size('desktop', Size(1440, 900), 1, EdgeInsets.zero),
];

final _out = Platform.environment['FIT_SHOTS'] ?? '';
final _only = Platform.environment['FIT_ONLY'] ?? '';
final _onlySize = Platform.environment['FIT_SIZE'] ?? '';
final _lib = Platform.environment['CAW_LIB'] ?? '';

class _Ctx {
  _Ctx(this.tester, this.size, this.light);
  final WidgetTester tester;
  final _Size size;
  final bool light;
  final errors = <String>[];

  /// Every layout error of the test, for the assertion at its end.
  final all = <String>[];
  String name = '';

  Future<void> shot(String suffix) async {
    final tester = this.tester;
    // Truncated text: every paragraph that hit its line limit or got clipped.
    final cut = <String>[];
    for (final e in find.byType(RichText).evaluate()) {
      final r = e.renderObject;
      if (r is RenderParagraph && r.attached && r.hasSize && r.didExceedMaxLines) {
        final t = r.text.toPlainText();
        if (t.trim().isNotEmpty) cut.add(t.length > 60 ? '${t.substring(0, 60)}…' : t);
      }
    }
    final id = '$name${suffix.isEmpty ? '' : '_$suffix'}_${size.name}_${light ? 'light' : 'dark'}';
    final small = <String>[];
    if (size.phone && _out.isNotEmpty) {
      final ev = await const MinimumTapTargetGuideline(size: Size(44, 44), link: '').evaluate(tester);
      if (!ev.passed) {
        for (final line in ev.reason!.split('\n')) {
          if (line.trim().isEmpty || line.startsWith('See also')) continue;
          small.add(line.length > 160 ? line.substring(0, 160) : line);
        }
      }
    }
    final log = File('$_out/report.jsonl');
    if (_out.isNotEmpty) {
      log.writeAsStringSync('${jsonEncode({'id': id, 'errors': errors, 'truncated': cut, 'small': small})}\n',
          mode: FileMode.append);
    }
    errors.clear();
    if (_out.isEmpty) return;
    await _write(id);
  }

  /// Scrolls the biggest vertical list to its end and shoots that too (what the safe area leaves of the last row).
  Future<void> end(String suffix) async {
    ScrollableState? best;
    double area = 0;
    for (final e in find.byType(Scrollable).evaluate()) {
      final st = (e as StatefulElement).state as ScrollableState;
      if (st.axisDirection != AxisDirection.down) continue;
      final box = e.renderObject as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final a = box.size.width * box.size.height;
      if (a > area && st.position.maxScrollExtent > 0) {
        area = a;
        best = st;
      }
    }
    if (best == null) return;
    best.position.jumpTo(best.position.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 300));
    await shot(suffix.isEmpty ? 'end' : '${suffix}_end');
  }

  Future<void> _write(String id) async {
    final el = find.byKey(goldenKey).evaluate().single;
    final bytes = await tester.runAsync(() async {
      final image = await captureImage(el);
      final b = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return b!;
    });
    File('$_out/$id.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  }
}

/// Pumps [child] like the app (theme, glass backdrop, the view's text scale and safe area).
Future<void> _pump(_Ctx c, Widget child) async {
  final tester = c.tester;
  await loadAppFonts(tester);
  imageCache
    ..clear()
    ..clearLiveImages();
  tester.view.physicalSize = c.size.size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding(top: c.size.pad.top, bottom: c.size.pad.bottom);
  tester.view.viewPadding = FakeViewPadding(top: c.size.pad.top, bottom: c.size.pad.bottom);
  tester.platformDispatcher.textScaleFactorTestValue = c.size.scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  // A Settings made by the screen's fixture puts its own theme in force: set the look last.
  Neon.active = c.light ? calmNeon.shown(true) : calmNeon;
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: Neon.theme(),
    builder: (context, ch) => RepaintBoundary(key: goldenKey, child: GlassBackdrop(child: ch ?? const SizedBox.shrink())),
    home: child,
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _settle(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 4));
  } catch (_) {
    await tester.pump(const Duration(seconds: 1));
  }
}

void _sweep(String name, Future<void> Function(_Ctx c) body, {bool engine = false}) {
  if (_only.isNotEmpty && !_only.split(',').any(name.startsWith)) return;
  for (final size in _sizes) {
    if (_onlySize.isNotEmpty && !_onlySize.split(',').contains(size.name)) continue;
    // The suite's run: the small phone, large text and a tablet, dark; the screenshot sweep adds the rest.
    if (_out.isEmpty && !const ['p360', 'p412x13', 'tablet'].contains(size.name)) continue;
    for (final light in _out.isEmpty ? const [false] : const [false, true]) {
      testWidgets('$name ${size.name} ${light ? 'light' : 'dark'}', (tester) async {
        final c = _Ctx(tester, size, light)..name = name;
        final handle = tester.ensureSemantics();
        Neon.active = light ? calmNeon.shown(true) : calmNeon;
        final prev = FlutterError.onError;
        FlutterError.onError = (d) {
          final s = d.exceptionAsString().split('\n').first;
          final where = d.toString().split('\n').where((l) => l.contains('file:///') || l.contains('created by')).take(2);
          c.errors.add('$s ${where.join(' ')}');
          c.all.add(c.errors.last);
        };
        try {
          await body(c);
        } catch (e, st) {
          c.errors.add('THREW: $e ${st.toString().split('\n').take(3).join(' | ')}');
          c.all.add(c.errors.last);
          try {
            await c.shot('threw');
          } catch (_) {}
        } finally {
          FlutterError.onError = prev;
          Neon.active = calmNeon;
          Glass.enabled = true;
          handle.dispose();
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 2));
        expect(c.all, isEmpty);
      }, skip: engine && _lib.isEmpty);
    }
  }
}

// --- fixtures ---

class _Relay implements RelayHttp {
  @override
  Future<RelayResponse> send(String method, Uri url, {required Map<String, String> headers, String? body}) async =>
      const RelayResponse(202);
}

class _Probe implements DeviceProbe {
  @override
  Future<DeviceFacts> read() async => const DeviceFacts(
      platform: 'android', osVersion: '14', cpu: 'SM8450', big: 4, little: 4, other: 0, maxClockMHz: [3000, 1800], ramGB: 8);
}

Future<Telemetry> _telemetry(WidgetTester tester) async {
  final t = Telemetry(
    config: TelemetryConfig.parse(channel: 'beta', relayUrl: 'https://relay.example.dev', appKey: 'k'),
    store: MemoryTelemetryStore(),
    http: _Relay(),
    probe: _Probe(),
    now: () => DateTime.utc(2026, 11, 12, 10),
    random: Random(3),
  );
  t.app
    ..appVersion = '1.0.0-alpha.1'
    ..engineVersion = '1.0.0-alpha.1'
    ..capiVersion = 23;
  await tester.runAsync(() async {
    await t.load();
    await t.acceptFirstRun();
  });
  return t;
}

Future<UpdateService> _updates(WidgetTester tester) async {
  final dir = Directory.systemTemp.createTempSync('caw-fit-upd');
  addTearDown(() => dir.deleteSync(recursive: true));
  final s = UpdateService(
    source: ListSource(parseGitHubReleases(sample)),
    fetcher: UpdateFetcher(transport: FakeTransport()),
    installer: FakeInstaller(dir),
    version: '1.0.0-alpha.1',
    build: '',
  );
  await tester.runAsync(() => s.check());
  return s;
}

Future<AppState> _engineState(WidgetTester tester, {bool distortion = false}) async {
  final s = AppState();
  s.engine = Engine.create();
  s.project = s.demoProject();
  if (distortion) s.project.layers.first.components.add(ComponentUseDoc('org.caw.distortion'));
  s.selectedModuleId = s.project.modules.first.id;
  s.ready = true;
  s.starting = false;
  await tester.runAsync(() async {
    s.info = await s.engine!.setProject(s.project.toEngineJson());
    s.componentCatalog.set(await s.engine!.nativeComponents());
  });
  addTearDown(s.dispose);
  return s;
}

SectionController _sections(WidgetTester tester) => SectionController.of(tester.element(find.byType(Scaffold).first));

BuildContext _navCtx(WidgetTester tester) => tester.element(find.byType(Scaffold).first);

class _HangJob implements StressJob {
  final _c = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> get result => _c.future;
  @override
  StressProgress progress() => const StressProgress(fraction: 0.4, load: 0.45);
  @override
  List<double> takeHistory() => const [0.3, 0.4, 0.5, 0.45];
  @override
  void cancel() {}
}

class _HangStress extends FakeStress {
  @override
  StressJob start(StressRequest r) => _HangJob();
}

MusicVideoDoc _video() => MusicVideoDoc(
      timeline: VideoTimeline([
        VideoCut(id: 's1', start: 0, length: 64, effects: [VideoEffect(kind: VideoEffectKind.glow, drive: VideoDrive.beat)]),
        VideoCut(id: 's2', start: 64, length: 64, layout: VideoLayout(preset: VideoLayoutPreset.bigStrip),
            transition: VideoTransition.wipe, transitionSteps: 4, texts: [VideoText(id: 't1', kind: VideoTextKind.title)]),
        VideoCut(id: 's3', start: 128, length: 128, layout: VideoLayout.single(VideoShot.falling)),
      ]),
      texts: [VideoText(id: 't2', text: 'Out now', y: 0.85)],
    );

void main() {
  if (_out.isNotEmpty) Directory(_out).createSync(recursive: true);

  // --- startup, first run, update prompt ---
  _sweep('startup', (c) async {
    final p = StartupProgress()
      ..finish(StartupStep.engine)
      ..finish(StartupStep.components)
      ..begin(StartupStep.projects);
    addTearDown(p.dispose);
    await _pump(c, StartupScreen(progress: p, version: '1.0.1-alpha.1', updateLine: 'Update available: v1.0.1-alpha.2'));
    await c.tester.pump(revealDuration);
    await c.shot('');
  });

  _sweep('firstrun', (c) async {
    await _pump(c, FirstRunPage(telemetryOn: true, onContinue: () {}));
    await _settle(c.tester);
    await c.shot('');
    await c.end('');
  });

  _sweep('updateprompt', (c) async {
    final svc = await _updates(c.tester);
    final state = AppState(settings: Settings());
    addTearDown(state.dispose);
    await _pump(c, UpdatePromptHost(state: state, service: svc, busy: () => false, settle: const Duration(milliseconds: 10),
        child: const Scaffold(body: SizedBox.expand())));
    state.ready = true;
    state.clipSelectionChanged();
    await c.tester.pump(const Duration(milliseconds: 50));
    await _settle(c.tester);
    await c.shot('');
    // Its text shows: on a phone the dialog is a sheet as tall as its content, buttons in one row.
    final body = c.tester.getRect(find.textContaining('Updating is up to you'));
    expect(body.height, greaterThan(10));
    expect(body.bottom, lessThanOrEqualTo(c.tester.getRect(find.byKey(const ValueKey('update-never'))).top));
  });

  // --- Settings ---
  for (final sec in SettingsSection.values) {
    _sweep('settings-${sec.name}', (c) async {
      final t = await _telemetry(c.tester);
      Telemetry.current = t;
      addTearDown(() => Telemetry.current = null);
      final svc = await _updates(c.tester);
      UpdateService.running = svc;
      addTearDown(() => UpdateService.running = null);
      await _pump(c, SettingsPage(settings: Settings(), initial: sec));
      await _settle(c.tester);
      if (c.size.size.width < 700) {
        await c.tester.scrollUntilVisible(find.text(sec.title), 200, scrollable: find.byType(Scrollable).first);
        await c.tester.tap(find.text(sec.title).first);
        await _settle(c.tester);
      }
      await c.shot('');
      await c.end('');
    });
  }
  _sweep('settings-list', (c) async {
    await _pump(c, SettingsPage(settings: Settings()));
    await _settle(c.tester);
    await c.shot('');
    await c.end('');
  });
  _sweep('privacy', (c) async {
    final t = await _telemetry(c.tester);
    Telemetry.current = t;
    addTearDown(() => Telemetry.current = null);
    await _pump(c, PrivacyPage(deps: SettingsDeps(settings: Settings())));
    await _settle(c.tester);
    await c.shot('');
    await c.end('');
  });

  // --- Benchmark ---
  _sweep('bench', (c) async {
    await _pump(c, BenchmarkScreen(runner: StressRunner(backend: FakeStress()), saveJson: (_) async => true,
        share: (_) async => true));
    await _settle(c.tester);
    await c.shot('idle');
    await c.tester.tap(find.byKey(const ValueKey('bench-quick')));
    await _settle(c.tester);
    await c.shot('results');
    await c.end('results');
  });
  _sweep('bench-running', (c) async {
    await _pump(c, BenchmarkScreen(runner: StressRunner(backend: _HangStress()), saveJson: (_) async => true,
        share: (_) async => true));
    await c.tester.tap(find.byKey(const ValueKey('bench-quick')));
    await c.tester.pump(const Duration(milliseconds: 600));
    await c.tester.pump(const Duration(milliseconds: 600));
    await c.shot('');
  });

  // --- feedback, background hint ---
  _sweep('feedback', (c) async {
    final t = await _telemetry(c.tester);
    await _pump(c, const Scaffold(body: SizedBox.expand()));
    unawaited(showFeedbackSheet(_navCtx(c.tester), t));
    await _settle(c.tester);
    await c.shot('');
    // A sheet's last button clears the system navigation bar.
    final send = find.text('Send');
    await c.tester.ensureVisible(send);
    await _settle(c.tester);
    expect(c.tester.getRect(send).bottom, lessThanOrEqualTo(c.size.size.height - c.size.pad.bottom));
    await c.end('');
  });

  // --- music video (no engine) ---
  for (final tab in VideoTab.values) {
    _sweep('video-${tab.name}', (c) async {
      clearVideoTextCache();
      final s = AppState(settings: Settings());
      addTearDown(s.dispose);
      s.project = videoTestSong()..musicVideo = _video().toJson();
      await _pump(c, const Scaffold(body: SizedBox.expand()));
      unawaited(showMusicVideoSheet(_navCtx(c.tester), s));
      await _settle(c.tester);
      final lane = find.byKey(const ValueKey('video-lane-shot-s2'));
      if (lane.evaluate().isNotEmpty) await c.tester.tap(lane.first, warnIfMissed: false);
      await c.tester.tap(find.byKey(ValueKey('video-tab-${tab.name}')).first);
      await _settle(c.tester);
      await c.shot('');
      await c.end('');
    });
  }
  _sweep('video-editor', (c) async {
    clearVideoTextCache();
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    s.project = videoTestSong();
    await _pump(c, Scaffold(body: MusicVideoEditorPage(state: s, doc: _video())));
    await _settle(c.tester);
    await c.shot('');
  });

  // --- device UIs (no engine) ---
  for (final id in ['org.caw.synth.flagship', 'org.caw.drums', 'org.caw.eq', 'org.caw.compressor', 'org.caw.reverb.pro',
    'org.caw.multiband', 'org.caw.delay.pro']) {
    _sweep('device-${id.substring(8)}', (c) async {
      final s = stateWith(id, make: PreviewState.new);
      addTearDown(s.dispose);
      await _pump(c, const Scaffold(body: SizedBox.expand()));
      openDevice(_navCtx(c.tester), s, id);
      await _settle(c.tester);
      await c.shot('');
      await c.end('');
    });
  }
  _sweep('fxbrowser', (c) async {
    final s = await _engineState(c.tester);
    await _pump(c, const Scaffold(body: SizedBox.expand()));
    unawaited(showAssetPicker(_navCtx(c.tester), s, kinds: {AssetKind.nativeEffect}));
    await _settle(c.tester);
    await c.shot('');
    await c.end('');
  }, engine: true);

  // --- Files with a library (no engine) ---
  _sweep('files', (c) async {
    final root = Directory.systemTemp.createTempSync('caw-fit-files');
    addTearDown(() => root.deleteSync(recursive: true));
    final storage = ProjectStorage(root);
    late AppState s;
    await c.tester.runAsync(() async {
      for (final (id, name, n) in [('alpha', 'Alpha jam', 3), ('beta', 'Beta sketch with a rather long name', 2),
        ('gamma', 'Old gamma', 1)]) {
        File('${root.path}/$id.json').writeAsStringSync(jsonEncode(ProjectDoc(id: id, name: name, bpm: 120, layers: [
          for (var i = 0; i < n; i++) LayerDoc(id: 'l$i', name: 'T$i', color: i),
        ]).toJson()));
      }
      await storage.setLastOpened('alpha');
      s = AppState();
      await s.openStorage(storage);
      final folder = storage.library.createFolder('Drafts');
      storage.library.moveProjects(['gamma'], folder.id);
      await storage.library.refresh();
    });
    addTearDown(s.dispose);
    await _pump(c, SectionScope(controller: SectionController(),
        child: Scaffold(body: FileManagerScreen(state: s, folder: 'projects'))));
    await _settle(c.tester);
    await c.shot('projects');
    final beta = find.text('Beta sketch with a rather long name');
    if (beta.evaluate().isNotEmpty) {
      await c.tester.longPress(beta.first);
      await _settle(c.tester);
      await c.shot('select');
    }
  });

  // --- engine screens: Shell sections, mixer, export ---
  _sweep('shell-arrange', (c) async {
    final s = await _engineState(c.tester);
    await _pump(c, Shell(state: s));
    await _settle(c.tester);
    await c.shot('');
  }, engine: true);
  _sweep('shell-build', (c) async {
    final s = await _engineState(c.tester);
    final doc = CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz');
    s.project.cppComponents.add(doc);
    await _pump(c, Shell(state: s));
    _sections(c.tester).openBuild(BuildTab(BuildTabKind.cpp, doc.componentId));
    await _settle(c.tester);
    await c.shot('cpp');
    _sections(c.tester).openBuild(BuildTab(BuildTabKind.pattern, s.project.modules.firstWhere((m) => s.isPattern(m.id)).id));
    await _settle(c.tester);
    await c.shot('roll');
  }, engine: true);
  _sweep('shell-files', (c) async {
    final s = await _engineState(c.tester);
    await _pump(c, Shell(state: s));
    _sections(c.tester).show(Section.files);
    await _settle(c.tester);
    await c.shot('');
  }, engine: true);
  _sweep('shell-focus', (c) async {
    final s = await _engineState(c.tester, distortion: true);
    await _pump(c, Shell(state: s));
    _sections(c.tester).focusLayer(s.project.layers.first.id);
    await _settle(c.tester);
    await c.shot('');
  }, engine: true);
  _sweep('hint', (c) async {
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    s.project = ProjectDoc(id: 'p', name: 'P');
    s.audioIo = FakeAudioIo();
    final b = BackgroundPlayback(s, FakePlaybackService());
    addTearDown(b.dispose);
    await _pump(c, Scaffold(body: BackgroundHintFeedback(playback: b, child: const SizedBox.expand())));
    b.hint.value = true;
    await _settle(c.tester);
    await c.shot('');
  });
  _sweep('mixer', (c) async {
    final s = await _engineState(c.tester);
    await _pump(c, Scaffold(body: MixerCard(state: s, onClose: () {})));
    await _settle(c.tester);
    await c.shot('');
  }, engine: true);
  _sweep('export', (c) async {
    final s = await _engineState(c.tester);
    await _pump(c, const Scaffold(body: SizedBox.expand()));
    unawaited(showExportPage(_navCtx(c.tester), s));
    await _settle(c.tester);
    await c.shot('');
    await c.end('');
  }, engine: true);
}
