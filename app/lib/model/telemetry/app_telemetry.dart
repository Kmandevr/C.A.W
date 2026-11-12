// Connects telemetry to the running app (main.dart): the meter reads AppState already makes, Play, frame timings,
// thermal and power signals, errors, startup time and what the engine reports, with no FFI call of its own.
import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../engine/bindings.dart' show cawApiVersion;
import '../../engine/execution.dart';
import '../../ui/frame_rate.dart';
import '../../version.dart';
import '../app_state.dart';
import '../problem_log.dart';
import '../live_midi.dart';
import '../settings.dart';
import 'peripherals.dart';
import 'device_probe.dart';
import 'telemetry.dart';
import 'telemetry_config.dart';

/// Starts telemetry for [state]: loads its file next to the settings, then follows the app. [startup] runs from
/// main()'s first line.
Future<Telemetry> startAppTelemetry(AppState state, {required Stopwatch startup, Directory? dir}) async {
  final base = dir ?? state.settings.dir;
  final t = Telemetry(
    config: TelemetryConfig.fromEnvironment(),
    store: base == null
        ? MemoryTelemetryStore()
        : FileTelemetryStore(File('${base.path}${Platform.pathSeparator}telemetry.json')),
    probe: IoDeviceProbe(),
  );
  final builtins = <String>{};
  final app = t.app
    ..appVersion = appVersion
    ..engineVersion = appVersion // the engine is built with the app; it reports no version of its own
    ..capiVersion = cawApiVersion
    ..build = t.config.build
    ..isBuiltin = builtins.contains;
  app.profile = () => switch (state.settings.performanceMode) {
        PerformanceMode.fullExperience => 'full',
        PerformanceMode.balanced => 'balanced',
        PerformanceMode.lightweight => 'lightweight',
        PerformanceMode.minimal => 'minimal',
      };
  app.eco = () => state.settings.soundQuality == SoundQuality.eco;
  app.refreshHz = () {
    final rates = FrameRateController.current?.rates ?? const <double>[];
    if (rates.isNotEmpty) return rates.reduce((a, b) => a > b ? a : b).round();
    final displays = WidgetsBinding.instance.platformDispatcher.displays;
    return displays.isEmpty ? 0 : displays.first.refreshRate.round();
  };
  app.display = () {
    final displays = WidgetsBinding.instance.platformDispatcher.displays;
    if (displays.isEmpty) return const {};
    final d = displays.first;
    int ten(double v) => (v / 10).round() * 10; // rounded to 10, as the relay keeps it
    final w = d.size.width, h = d.size.height;
    return {'widthPx': ten(w > h ? w : h), 'heightPx': ten(w > h ? h : w), 'displays': displays.length};
  };
  // Android tells a phone from a tablet by the screen's shortest side (600 dp, the app's own tablet line).
  app.formFactor = () {
    if (!Platform.isAndroid) return 'unknown';
    final displays = WidgetsBinding.instance.platformDispatcher.displays;
    if (displays.isEmpty) return 'unknown';
    final d = displays.first;
    return d.size.shortestSide / d.devicePixelRatio >= 600 ? 'tablet' : 'phone';
  };
  app.audioOutput = () => connectionOf(state.latency.routeInfo.output.kind);
  app.peripherals = () =>
      peripheralsOf(route: state.latency.routeInfo, midi: LiveMidi.current?.ports ?? const []);
  app.audio = () {
    final a = state.audioStatus;
    if (a == null || !a.running) return const {};
    return {
      'backend': a.backend.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_'),
      'exclusive': a.exclusive,
      'lowLatency': a.lowLatency,
      'bufferFrames': a.periodFrames,
      'sampleRate': a.sampleRate,
    };
  };
  await t.load();
  Telemetry.current = t;

  // The 30 Hz meter reads AppState already makes, and Play.
  var playing = false;
  state.tick.addListener(() {
    final m = state.meters;
    t.onMeters(cpu: m.cpu, playing: m.playing, overloaded: m.overloaded);
    if (m.playing && !playing) {
      final p = state.project;
      final own = {for (final c in p.cppComponents) c.componentId};
      t.onPlay(
        componentIds: [
          for (final l in p.layers) ...[?l.instrument?.id, for (final c in l.components) c.id, for (final c in l.noteComponents) c.id],
          for (final c in p.masterComponents) c.id,
        ].where((id) => !own.contains(id)),
        tracks: p.layers.length,
        clips: p.layers.fold(0, (n, l) => n + l.clips.length + l.audioClips.length),
      );
    }
    playing = m.playing;
  });

  // Frame build and raster times (Flutter reports them in batches; cheap).
  SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
    if (!t.enabled) return;
    for (final f in timings) {
      t.onFrame(f.totalSpan.inMicroseconds / 1000);
    }
  });

  // Thermal and battery saver, as AppState already follows them (a second listener on the platform's event channel
  // would take it over), read every 30 s.
  void pressure() {
    final p = EngineExecutionPolicy.runtimePressure;
    t.onPressure(
        hot: p == EnginePressure.thermalHot || p == EnginePressure.thermalCritical,
        batterySaver: p == EnginePressure.batterySaver);
  }

  Timer.periodic(const Duration(seconds: 30), (_) => pressure());

  ProblemLog.onError = t.onError;
  AppLifecycleListener(
    onResume: () => t.foreground = true,
    onInactive: () => t.foreground = true,
    onHide: () => t.foreground = false,
    onPause: () => t.foreground = false,
  );

  // Startup: from main() to the first project open; the built-ins once the engine has loaded.
  void ready() {
    if (!state.ready) return;
    state.removeListener(ready);
    t.onStartup(startup.elapsedMilliseconds);
    final e = state.engine;
    if (e != null) {
      unawaited(e.nativeComponents().then((list) {
        builtins.addAll([for (final c in list) if (c.builtin) c.id]);
      }, onError: (Object _) {}));
    }
  }

  state.addListener(ready);
  ready();
  t.start();
  return t;
}
