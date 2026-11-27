// AppState's playback: the heard meters, the audio device and its choice, test tones, the transport and the Arrange view.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of '../app_state.dart';

extension AppStatePlayback on AppState {
  // The output's underruns since it opened (-1: the platform can't say), from the status's clock diagnostic.
  int _outputDropouts(Engine e) {
    if (!e.audioOn) return -1;
    final clock = e.audioStatusJson()['clock'];
    return clock is Map && clock['xruns'] is int ? clock['xruns'] as int : -1;
  }

  // The output buffer's automatic size (#236; Settings.bufferTuning, on by default since 1.1.2): once a second while playing,
  // and the size it settles on kept per kind of output, where the next stream on that kind starts.
  void _tuneBuffer(Engine e, int now) {
    _tuneReadUs = now;
    final kind = latency.routeInfo.output.kind.name;
    final frames = e.tuneAudioBuffer(settings.tunedBufferFrames[kind] ?? 0);
    if (frames > 0 && settings.tunedBufferFrames[kind] != frames) {
      settings.update((s) => s.tunedBufferFrames[kind] = frames);
    }
  }
  /// How long after rendering a sample is heard, in microseconds (0 with compensation off).
  int get outputLatencyUs => (latency.outputMs * 1000).round();

  /// The meter read whose span (since the read before it) holds [us] on [nowUs]'s clock; while compensation holds
  /// the first reads back, a silent one (nothing of them is heard yet). Null only when nothing was read at all.
  MeterReading? meterAt(int us) {
    final newest = meterTimeline.newest;
    if (newest == null) return null;
    return meterTimeline.covering(us, spanUs: _poller.interval.inMicroseconds) ??
        MeterReading(us, EngineMeters(playing: false, loopLength: newest.meters.loopLength), const []);
  }

  /// The master meters as heard ([meters] is what was just rendered): what peak meters should read.
  EngineMeters get audibleMeters {
    final r = audibleReading.meters;
    final m = meters;
    // The transport's state and overloads are now's; the levels are the heard ones.
    return EngineMeters(cpu: m.cpu, peakL: r.peakL, peakR: r.peakR, playing: m.playing, overloaded: m.overloaded,
        position: r.position, loopLength: m.loopLength, step: r.step);
  }

  /// Each track's meter as heard ([layerMeters] is what was just rendered).
  List<LayerMeterValue> get audibleLayerMeters {
    if (outputLatencyUs <= 0) return layerMeters;
    final heard = audibleReading.layers;
    return [for (var i = 0; i < layerMeters.length; i++) i < heard.length ? heard[i] : const LayerMeterValue()];
  }

  /// The output latency in sixteenth steps at the project's tempo.
  double get outputLatencySteps => latency.outputMs / 1000 * project.bpm / 15;

  /// The song step a meter read stands for: the engine's own, on its tempo map (caw_engine_position, API 31), else
  /// its position through the loop converted over the project's map.
  double meterStep(EngineMeters m) => m.step ?? project.stepAtLoopFraction(m.position / m.loopLength);

  /// Where the engine renders now, in sixteenth steps (playing; [playheadStep] is where the ear is).
  double get renderStep {
    final m = meters;
    if (m.playing && m.loopLength > 0) return meterStep(m);
    return pausedStep ?? 0;
  }

  /// [step] rendered now, moved back to where the ear is: an output latency earlier, wrapped back over the loop
  /// (the loop range when on, else the song) and held at where play began until the first sound is heard.
  double heardStep(double step, {int? atUs}) {
    final lat = outputLatencySteps;
    if (lat <= 0) return step;
    if ((atUs ?? nowUs) - _playStartUs < outputLatencyUs) return _playStartStep;
    final p = project;
    final (from, to) = p.loopsRange
        ? (p.loopStartSteps.toDouble(), p.loopEndSteps.toDouble())
        : (0.0, p.engineLoopSteps.toDouble());
    var s = step - lat;
    final span = to - from;
    if (span > 0) {
      while (s < from && step >= from) {
        s += span;
      }
    }
    return s < 0 ? 0 : s;
  }

  void _markPlayStart(double step) {
    _playStartUs = nowUs;
    _playStartStep = step;
    meterTimeline.clear();
  }

  /// Completes when the last device choice has reached the engine (tests).
  @visibleForTesting
  Future<void> get audioConfigured => _audioConfigured;
  /// Sends the sound quality, the device's choice (device, callback size, exclusive mode), the click's sound and the
  /// buffer mode to the engine when they (or whether a recording runs) changed. A device choice reopens a running
  /// device on a background isolate (the engine's device lock; never in the callback or on the UI isolate); when the
  /// choice doesn't open, the system default plays instead and [audioError] says so.
  void applyAudioSettings({bool? recording}) {
    final e = engine;
    if (e == null) return;
    if (_quality != settings.soundQuality) {
      _quality = settings.soundQuality;
      e.setQuality(settings.soundQuality.index);
    }
    final device =
        '${settings.audioDeviceId}|${settings.audioDevice}|${settings.bufferFrames}|${settings.exclusiveAudio}';
    if (_deviceChoice != device) {
      _deviceChoice = device;
      _configureDevice(e, device);
    }
    final click = '${settings.clickVolume}|${settings.clickSound.index}';
    if (_clickChoice != click) {
      _clickChoice = click;
      e.setMetronomeSound(settings.clickVolume, settings.clickSound.index);
    }
    // The live output's safety limiter and mono check (API 35, #244): never in an export.
    final safety = (settings.safetyLimiter, settings.monoCheck);
    if (_safetyChoice != safety) {
      _safetyChoice = safety;
      e.setOutputSafety(limiter: settings.safetyLimiter, mono: settings.monoCheck);
    }
    final rec = recording ?? _bufferRecording ?? false;
    if (_buffer != settings.audioBuffer || _bufferRecording != rec) {
      _buffer = settings.audioBuffer;
      _bufferRecording = rec;
      e.setBufferMode(settings.audioBuffer.index, recording: rec);
    }
  }

  // The device choice to the engine. A choice from the platform's own list (#242: Android's devices by type and
  // name) opens by the id that device has now, '' (the default) while it is not connected; any other saved id goes
  // as it is (WASAPI's endpoint id). A name only is still looked up by the engine.
  void _configureDevice(Engine e, String device) {
    final key = settings.audioDeviceId;
    final name = settings.audioDevice;
    final platform = key.startsWith(platformChoicePrefix);
    _routeSub ??= latency.route.changes.listen((_) => _deviceListChanged());
    _audioConfigured = _audioConfigured.then((_) async {
      if (_disposed || _deviceChoice != device) return;
      final choices = platform ? platformChoices((await latency.route.devices()).outputs, input: false) : const <AudioChoice>[];
      final id = engineDeviceId(key, choices);
      final missing = platform && id.isEmpty;
      _openedDeviceId = id;
      final result = await e.configureAudio(
          deviceId: id, device: platform ? '' : name, periodFrames: settings.bufferFrames, exclusive: settings.exclusiveAudio);
      if (_disposed || _deviceChoice != device) return;  // a newer choice will report for itself
      final before = audioError;
      audioError = switch (result) {
        AudioConfigured.ok when missing => _fallbackNote = '${name.isEmpty ? 'The chosen output' : name} is not connected; '
            'using the default',
        AudioConfigured.ok => audioError == _fallbackNote ? null : audioError,
        AudioConfigured.fallback => _fallbackNote = 'Couldn\'t open ${name.isEmpty ? 'the chosen size or mode' : name}; '
            'using the default',
        AudioConfigured.closed => 'The audio device did not reopen with the new settings',
      };
      if (audioError != before) notifyListeners();
    }).catchError((Object _) {});
  }

  // A device connected or went away: a platform choice opens again where its id changed (it reconnected with a new
  // one, or it is back after the default played meanwhile), and nothing reopens otherwise.
  Future<void> _deviceListChanged() async {
    final e = engine;
    final key = settings.audioDeviceId;
    if (e == null || _disposed || !key.startsWith(platformChoicePrefix) || _deviceChoice == null) return;
    final id = engineDeviceId(key, platformChoices((await latency.route.devices()).outputs, input: false));
    if (_disposed || id == _openedDeviceId) return;
    _configureDevice(e, _deviceChoice!);
  }

  int get tempoTapCount => _tempoTaps.length;
  /// Opens the audio device for the sample preview when it was closed while idle; an error message when it can't.
  String? openAudioForPreview() {
    final e = engine;
    if (e == null) return engineError ?? 'The sound engine did not load';
    if (useAudioDevice && !e.audioOn) {
      final error = _openAudio(e);
      if (error != null) return error;
    }
    _poller.wake();
    return null;
  }

  /// Records a tempo tap; pauses over two seconds restart the measurement.
  /// [at] is injectable for deterministic tests.
  void tapTempo({DateTime? at}) {
    final now = at ?? tapClock();
    if (_tempoTaps.isNotEmpty && now.difference(_tempoTaps.last) > const Duration(seconds: 2)) {
      _tempoTaps.clear();
    }
    if (_tempoTaps.isNotEmpty && !now.isAfter(_tempoTaps.last)) return;
    _tempoTaps.add(now);
    if (_tempoTaps.length > 5) _tempoTaps.removeAt(0);
    if (_tempoTaps.length >= 2) {
      final elapsed = now.difference(_tempoTaps.first).inMicroseconds;
      final intervals = _tempoTaps.length - 1;
      if (elapsed > 0) {
        final bpm = (60000000.0 * intervals / elapsed).clamp(20.0, 400.0);
        editProject((p) => p.bpm = double.parse(bpm.toStringAsFixed(1)));
        return;
      }
    }
    notifyListeners();
  }

  /// Where ⏮ goes: the loop start while a loop range plays, else the project start (sixteenth steps).
  int get startStep => project.loopsRange ? project.loopStartSteps : 0;

  /// The transport's ⏮ (Home; with [projectStart], a double tap or Ctrl+Home): moves the playhead to [startStep] or
  /// the project start. Playing, playback goes on from there; stopped, it only moves (a stop at the project start
  /// stays a stop). It also asks the views to come back ([revealStartRequests]).
  void backToStart({bool projectStart = false}) {
    final at = projectStart ? 0 : startStep;
    if (_transportOn || pausedStep != null || at != 0) {
      seekTo(at.toDouble());
    } else {
      notifyListeners();
    }
    requestRevealStart(step: at.toDouble(), always: projectStart);
  }

  /// Asks the views (Arrange, an open piano roll) to come back to [step]: with [always] they scroll there, else each
  /// scrolls only when [step] is off its screen (the view decides).
  void requestRevealStart({double step = 0, bool always = true}) {
    revealStartRequests.value =
        RevealStartRequest(step, always: always, serial: (revealStartRequests.value?.serial ?? 0) + 1);
  }

  // Hands the read just taken to [playheadClock], over the range [heardStep] wraps in.
  void _readPlayhead() {
    final p = project;
    final (from, to) = p.loopsRange
        ? (p.loopStartSteps.toDouble(), p.loopEndSteps.toDouble())
        : (0.0, p.engineLoopSteps.toDouble());
    // The step rendered at this very moment (caw_engine_position_at on the MIDI clock, worked out from the last
    // callback's start) rather than at the last callback's end: a read then lags by however long ago that callback
    // ran, up to a whole callback (21 ms at 1024 frames), a jitter the line would show (#241).
    var step = playheadStep;
    final e = engine;
    final m = meters;
    final rate = latency.device.sampleRate;
    if (e != null && m.playing && m.loopLength > 0 && rate > 0) {
      final at = e.positionAt(e.midiClockNs);
      if (at >= 0) {
        // How far now lies from the read's own position (its callback's end), wrapped to the nearest; a loop
        // range's wrap between them reads far off and is left as it was.
        var d = (at - m.position) % m.loopLength;
        if (d > m.loopLength / 2) d -= m.loopLength;
        if (d.abs() < rate / 10) step = heardStep(meterStep(m) + d / rate * project.bpm / 15);
      }
    }
    playheadClock.read(
        step: step,
        atUs: nowUs,
        playing: meters.playing && meters.loopLength > 0,
        stepsPerSecond: p.bpm / 15,
        from: from,
        to: to);
  }

  /// True while the Benchmark runs: the transport is stopped and the device closed, and nothing reopens it (the
  /// Benchmark's own engine has the device for its live steps; one output per process).
  bool get stressSuspended => _stressSuspended;
  void clearOverload() {
    engine?.clearOverload();
    _poller.wake();
    notifyListeners();
  }

  /// Keeps the arrangement's view for the open project (Settings.rememberZoom on): on leaving a project, going to
  /// the background, and when the arranger closes.
  void rememberArrangeView() {
    if (!settings.rememberZoom) return;
    final view = readArrangeView?.call();
    if (view == null || settings.projectViews[project.id] == view) return;
    settings.rememberProjectView(project.id, view);
    unawaited(settings.save());
  }

  /// The open project's remembered view, while Remember zoom per project is on.
  ArrangeView? get savedArrangeView => settings.rememberZoom ? settings.projectViews[project.id] : null;

  /// Called when the app goes to the background or returns. Playing, the output keeps running behind (nothing on
  /// this path waits on the audio thread); stopped, the device closes and reopens on return. On return a device the
  /// system stopped while away (a disconnect that could not be reopened) opens again too.
  void lifecycle({required bool foreground}) {
    _poller.setVisible(foreground);
    this.foreground.value = foreground;
    foreground ? _spent.start() : _spent.stop();
    final e = engine;
    if (e == null) return;
    // A throttled stretch in the background must not thin the song for good: layers the engine shed come back
    // and its load history is forgotten, going away and coming back (the engine sheds again if it must).
    e.clearOverload();
    if (!foreground) {
      rememberArrangeView();
      flush();
      if (!meters.playing) e.stopAudio();
    } else if (!e.audioOn || !e.audioStatus().running) {
      _openAudio(e);
      notifyListeners();
    }
  }

  /// A device the system stopped while the transport plays (miniaudio gives up on an AAudio stream it could not
  /// reopen after a disconnect or an error, AAudio's callback timing out among them, and the status then says not
  /// running) opens again; true when it had to. Called by the meter poll once a second while the transport plays,
  /// and by the background playback's slow check while the app is behind. Load and heat never stop playback (1.1.2):
  /// a device the app had marked closed (a reopen that failed) is opened again too, not left stalled until Play.
  bool checkAudioDevice() {
    final e = engine;
    if (e == null || !useAudioDevice || !_transportOn || _stressSuspended) return false;
    if (e.audioOn && e.audioStatus().running) return false;
    _openAudio(e);
    notifyListeners();
    return true;
  }

  /// Behind the app with the transport stopped (the notification's Stop): the device closes as it does when the
  /// app goes behind stopped, and reopens on return.
  void releaseAudioBehind() {
    if (!foreground.value && !meters.playing && !_transportOn) engine?.stopAudio();
  }

  /// Opens the device: null when it runs, else why not ([audioError] either way). It may run on the system default
  /// because the chosen device didn't open: it plays, and [audioError] says so.
  String? _openAudio(Engine e) {
    if (_stressSuspended) return 'The Benchmark is running'; // its own engine has the device
    final error = e.startAudio();
    if (error != null) return audioError = error;
    _audioOpened(e);
    return null;
  }

  /// [_openAudio] with the device opened on a background isolate (launch: the UI keeps drawing meanwhile).
  Future<String?> _openAudioOffThread(Engine e) async {
    if (_stressSuspended) return 'The Benchmark is running';
    final error = await e.startAudioOffThread();
    if (error != null) return audioError = error;
    _audioOpened(e);
    return null;
  }

  // The device has opened: its latency and whether it fell back to the default.
  void _audioOpened(Engine e) {
    latency.readDevice = e.audioLatency;
    _latencyReadUs = nowUs;
    unawaited(latency.refresh());
    final st = e.audioStatus();
    if (st.fallback) {
      final name = settings.audioDevice;
      audioError = _fallbackNote =
          'Couldn\'t open ${name.isEmpty ? 'the chosen size or mode' : name}; using the default';
    } else {
      audioError = null;
    }
  }
}
