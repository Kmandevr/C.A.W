// Entry point: loads the settings, starts the app state (engine, audio, startup choice) and shows the shell.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'model/app_state.dart';
import 'model/audio_record.dart';
import 'model/automation_writer.dart';
import 'model/background_playback.dart';
import 'model/live_midi.dart';
import 'model/problem_log.dart';
import 'model/settings.dart';
import 'platform/desktop_window.dart';
import 'platform/display_rate.dart';
import 'platform/haptics_device.dart';
import 'platform/mic_permission.dart';
import 'platform/playback_service.dart';
import 'platform/midi_input.dart';
import 'ui/frame_rate.dart';
import 'ui/glass.dart';
import 'ui/haptics.dart';
import 'ui/keyboard/keyboard_layer.dart';
import 'ui/page_closer.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Open beta: errors are kept (on the device only) for "Report a problem", then handled as before.
  final flutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    ProblemLog.add(details.exception, details.stack);
    flutterError?.call(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    ProblemLog.add(error, stack);
    return false;
  };
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['JetBrains Mono'], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  Haptics.device = platformHapticsDevice(); // the vibrator's fine primitives on Android
  DesktopWindow.current = platformDesktopWindow(); // the window's title and files opened with or dropped on it
  final settings = await Settings.open();
  // The frame-rate setting: the screen's rates, then Auto's idle drop or the cap (Settings keeps its cap up to date).
  final frameRate = FrameRateController(device: platformDisplayRate())..setCap(settings.frameRate);
  FrameRateController.current = frameRate;
  unawaited(frameRate.start());
  final state = AppState(settings: settings);
  // One MIDI listener for the app's life, above the shell (which a theme change rebuilds).
  LiveMidi.current = LiveMidi(state, platformMidiInput(clock: () => state.engine?.midiClockNs ?? 0));
  AutomationWriter.current = AutomationWriter(state); // the transport's Automate button
  // Audio recording follows the transport's Record (armed audio tracks); the input choice is app-wide.
  final midi = LiveMidi.current!;
  AudioRecorder.current = AudioRecorder(state, permission: platformMicPermission())
    ..follow(midi, () => midi.recording)
    ..load();

  // Background playback: Android's foreground service while playing or recording, its notification driving the
  // transport (background_playback.dart).
  BackgroundPlayback.current = BackgroundPlayback(state, platformPlaybackService());

  runApp(CawApp(state: state));
  state.init();
}

class CawApp extends StatefulWidget {
  const CawApp({super.key, required this.state});
  final AppState state;

  @override
  State<CawApp> createState() => _CawAppState();
}

class _CawAppState extends State<CawApp> with WidgetsBindingObserver {
  AppState get state => widget.state;

  // Which route is in front, for Esc and the mouse's Back button on closable pages.
  final PageCloserObserver _closer = PageCloserObserver();

  // The theme with what it was made from: a change that leaves the look alone keeps the same theme, so nothing that
  // reads the theme rebuilds for it.
  ThemeData? _theme;
  Object? _themeFrom;

  ThemeData _themeFor(Settings s) {
    final from = (s.activeTheme, s.compact, Glass.active, s.uiFont, s.roundness);
    if (_theme == null || from != _themeFrom) {
      _theme = Neon.theme(look: s.activeTheme, compact: s.compact, fontFamily: s.uiFont.family, roundness: s.roundness);
      _themeFrom = from;
    }
    return _theme!;
  }

  @override
  void initState() {
    super.initState();
    // The system's light or dark mode, for Mode: Follow system (known before the first frame, then followed live).
    WidgetsBinding.instance.addObserver(this);
    state.settings.setPlatformBrightness(WidgetsBinding.instance.platformDispatcher.platformBrightness, quiet: true);
    state.settings.addListener(_settingsChanged);
  }

  @override
  void didChangePlatformBrightness() =>
      state.settings.setPlatformBrightness(WidgetsBinding.instance.platformDispatcher.platformBrightness);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    state.settings.removeListener(_settingsChanged);
    super.dispose();
  }

  // A Settings slider being dragged (adjust) is shown by the Settings page itself: the app around it stays as it is.
  void _settingsChanged() {
    if (!state.settings.adjusting) setState(() {});
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'C.A.W',
    debugShowCheckedModeBanner: false,
    themeAnimationDuration: Duration.zero, // theme edits repaint once, with no animation frames
    theme: _themeFor(state.settings),
    navigatorObservers: [_closer],
    // The glass backdrop sits behind every route (glass off: the plain background). The theme's text size scales
    // the system's.
    builder: (context, child) {
      // Keys from a page, menu or sheet in front reach the key router; the focus ring and the hint strip draw on top.
      final body = GlassBackdrop(child: PageCloser(observer: _closer,
          child: KeyboardLayer(observer: _closer, child: child ?? const SizedBox.shrink())));
      final scale = state.settings.textScale;
      if (scale == 1) return body;
      final mq = MediaQuery.of(context);
      return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(16) / 16 * scale)), child: body);
    },
    // A new key after a theme or glass change (including a profile that turns glass or blur off) rebuilds every screen, so colours fixed at build time repaint too.
    home: Shell(key: ValueKey((state.settings.lookRevision, Glass.active, Glass.blurChosen)), state: state),
  );
}
