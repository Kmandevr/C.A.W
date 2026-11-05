// Tests saving and loading the settings and custom themes.
import 'dart:io';

import 'package:caw/model/settings.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('caw_settings'));
  tearDown(() {
    dir.deleteSync(recursive: true);
    Neon.active = calmNeon;
    Neon.performanceMode = PerformanceMode.balanced.index;
    Neon.light = false;
    Neon.showScopes = true;
  });

  test('defaults: Calm neon, comfortable, auto-update on at 400 ms, swap now', () async {
    final s = await Settings.open(base: dir);
    expect(s.themeName, 'Calm neon');
    expect(s.density, Density.comfortable);
    expect(s.liveUpdate, isTrue);
    expect(s.liveDelayMs, 400);
    expect(s.swapTiming, SwapTiming.now);
    expect(s.performanceMode, PerformanceMode.balanced);
  });

  test('settings and a custom theme are saved and loaded back', () async {
    final s = await Settings.open(base: dir);
    await s.update((x) {
      x.density = Density.compact;
      x.liveUpdate = false;
      x.liveDelayMs = 750;
      x.swapTiming = SwapTiming.bar;
    });
    final mine = calmNeon.copyWith(name: 'Mine').withColor('bg', const Color(0xFF123456));
    await s.saveTheme(mine);
    expect(Neon.bg.toARGB32(), 0xFF123456);

    final back = await Settings.open(base: dir);
    expect(back.density, Density.compact);
    expect(back.liveUpdate, isFalse);
    expect(back.liveDelayMs, 750);
    expect(back.swapTiming, SwapTiming.bar);
    expect(back.themeName, 'Mine');
    expect(back.theme['bg'].toARGB32(), 0xFF123456);
    expect(File('${dir.path}/themes/Mine.theme').readAsStringSync(), contains('kind: theme'));
  });


  test('performance profiles persist and legacy light mode migrates', () async {
    final s = await Settings.open(base: dir);
    await s.update((x) => x.performanceMode = PerformanceMode.minimal);
    expect(Neon.performanceMode, PerformanceMode.minimal.index);
    expect(Neon.showScopes, isFalse);

    final back = await Settings.open(base: dir);
    expect(back.performanceMode, PerformanceMode.minimal);
    expect(back.lightMode, isTrue);
    expect(Neon.showScopes, isFalse);

    await back.update((x) => x.performanceMode = PerformanceMode.lightweight);
    expect(Neon.showScopes, isTrue);
    expect(Neon.light, isTrue);
    expect(Neon.glow(Neon.green), isEmpty);

    final legacy = Settings();
    legacy.fromJson({'light_mode': true});
    expect(legacy.performanceMode, PerformanceMode.lightweight);
    legacy.fromJson({'light_mode': false});
    expect(legacy.performanceMode, PerformanceMode.balanced);
  });

  test('export profiles and recent history persist with bounded metadata', () async {
    final settings = await Settings.open(base: dir);
    await settings.saveExportProfile(const ExportProfile(
      name: 'Master WAV', kind: 'loop', sampleRate: 44100, float32: true, seconds: 12, frames: 32,
    ));
    final now = DateTime.now().millisecondsSinceEpoch;
    await settings.recordExport(ExportHistoryEntry(
      fileName: 'Song_120bpm_4bars.wav', kind: 'loop', createdAtMs: now,
      sampleRate: 44100, float32: true, seconds: 12, frames: 32,
      target: 'pattern-1', param: 'cutoff',
    ));

    final back = await Settings.open(base: dir);
    expect(back.exportProfiles, hasLength(1));
    expect(back.exportProfiles.single.name, 'Master WAV');
    expect(back.exportProfiles.single.sampleRate, 44100);
    expect(back.exportProfiles.single.float32, isTrue);
    expect(back.exportHistory, hasLength(1));
    expect(back.exportHistory.single.fileName, 'Song_120bpm_4bars.wav');
    expect(back.exportHistory.single.createdAtMs, now);
    expect(back.exportHistory.single.target, 'pattern-1');
    expect(back.exportHistory.single.param, 'cutoff');

    final malformed = Settings();
    malformed.fromJson({
      'export_profiles': [
        {'name': '  ', 'kind': 'loop'},
        {'name': 'Unsupported', 'kind': 'flac'},
        {'name': 'Valid', 'kind': 'midi', 'sample_rate': 'bad', 'seconds': 'bad'},
      ],
      'export_history': [
        {'file_name': 'missing timestamp', 'kind': 'loop'},
        {'file_name': 'Valid.mid', 'kind': 'midi', 'created_at_ms': now, 'sample_rate': 96000},
      ],
    });
    expect(malformed.exportProfiles, hasLength(1));
    expect(malformed.exportProfiles.single.sampleRate, 48000);
    expect(malformed.exportProfiles.single.seconds, 8);
    expect(malformed.exportHistory, hasLength(1));
    expect(malformed.exportHistory.single.sampleRate, 48000);
  });

  test('the roll\'s look and touch choices are saved, loaded and clamped', () async {
    final s = await Settings.open(base: dir);
    expect(s.roll.emptyDrag, EmptyDrag.scroll);
    await s.update((x) => x.roll = x.roll.copyWith(rowHeight: 24, emptyDrag: EmptyDrag.select, keyLabels: KeyLabels.all));
    final back = await Settings.open(base: dir);
    expect(back.roll.rowHeight, 24);
    expect(back.roll.emptyDrag, EmptyDrag.select);
    expect(back.roll.keyLabels, KeyLabels.all);
    expect(RollLook.fromJson({'row_height': 999, 'hold_ms': 1}).rowHeight, 40);
    expect(RollLook.fromJson({'row_height': 999, 'hold_ms': 1}).holdMs, 250);
  });

  test('the code editor\'s layout is saved, loaded and kept in range', () async {
    final s = await Settings.open(base: dir);
    expect(s.editor.keyRow, EditorLook.defaultKeyRow);
    await s.update((x) => x.editor = x.editor.copyWith(keyRow: ['t', 'sine(', 'let ', '  '], chipLetters: 9, barOnTop: true));
    final back = await Settings.open(base: dir);
    expect(back.editor.keyRow, ['t', 'sine(', 'let '], reason: 'blank keys are dropped, a trailing space is kept');
    expect(back.editor.chipLetters, 4);
    expect(back.editor.barOnTop, isTrue);
  });

  test('a starter theme is never overwritten: saving it makes a copy', () async {
    final s = await Settings.open(base: dir);
    final saved = await s.saveTheme(calmNeon.withColor('pink', const Color(0xFF00FF00)));
    expect(saved.name, 'Calm neon copy');
    expect(s.themeNamed('Calm neon')['pink'].toARGB32(), 0xFFFF2BD6);
    await s.deleteTheme(saved.name);
    expect(s.themeName, 'Calm neon');
    expect(s.customThemes, isEmpty);
  });

  test('damaged settings fall back to the defaults', () async {
    File('${dir.path}/settings.json').writeAsStringSync('{not json');
    final s = await Settings.open(base: dir);
    expect(s.liveDelayMs, 400);
  });
}
