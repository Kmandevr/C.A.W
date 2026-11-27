// AppState's engine: startup, the starter and demo projects, previews, the engine JSON, live coding, sync and autosave.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of '../app_state.dart';

extension AppStateEngineSync on AppState {
  TempoEngine? get _tempoTarget => tempoEngine ?? switch (engine) { final TempoEngine t => t, _ => null };

  /// Hands the tempo map and signatures to the engine after each project sync (the project JSON's `bpm` may have
  /// replaced its map with one point). A plain project (one tempo, one n/4) needs nothing past the JSON, but is
  /// sent once after a map was, so the engine drops the old one.
  void pushTempo() {
    final t = _tempoTarget;
    final p = project;
    if (t == null) return;
    final sent = _tempoSent;
    if (p.plainTempo && (sent == null || (listEquals(sent.$1, p.tempoMap) && listEquals(sent.$2, p.timeSignatures)))) {
      return;
    }
    t.setTempoMap(p.tempoMap);
    t.setTimeSignatures(p.timeSignatures);
    _tempoSent = (p.tempoMap, p.timeSignatures);
  }
  Future<void> init() async {
    // Everything runs inside the try, so whatever throws, the finally shows the app ([StartupGate] also gives up
    // waiting after its timeout, for a step that never ends).
    try {
      startup.begin(StartupStep.engine);
      try {
        await latency.load();
        _resourcePressureSubscription = ResourceSignals.changes.listen(
          (p) {
            EngineExecutionPolicy.updateRuntimeSignals(pressure: p);
            pressure.value = p;
          },
          onError: (Object _) => EngineExecutionPolicy.updateRuntimeSignals(pressure: EnginePressure.unknown),
        );
        final now = await readPressure();
        EngineExecutionPolicy.updateRuntimeSignals(pressure: now);
        pressure.value = now;
        if (Platform.isAndroid) {
          Future<void> readHeadroom() async {
            final h = (await ResourceSignals.readThermal())['headroom'];
            if (!_disposed) thermalHeadroom.value = h is num ? h.toDouble() : null;
          }
          unawaited(readHeadroom());
          _headroomTimer = Timer.periodic(const Duration(seconds: 10), (_) => unawaited(readHeadroom()));
        }
      } catch (_) {
        // The signals are optional: the policy stays conservative without them.
        EngineExecutionPolicy.updateRuntimeSignals(pressure: EnginePressure.unknown);
      }
      try {
        engine = await createEngine(settings.sampleRate);
        DeviceSlotAudio.current = EngineSlotAudio.instance;  // per-slot meters and auto gain (device shell)
        MergedDevices.resolver = Engine.resolveComponent;  // old presets' effects as merged devices (user_presets.dart)
        applyAudioSettings();  // before the device opens, so it opens on the chosen device at the chosen size
        hardwareProfile = EngineExecutionPolicy.hardwareProfile;
        auditionPlan = EngineExecutionPolicy.plan(workload: EngineWorkload.interactiveAudition);
        await _audioConfigured;  // the choice is in the engine before the device opens (no reopen right after)
        await _openAudioOffThread(engine!);  // opening the device can take tens of milliseconds
        startup.finish(StartupStep.engine);
      } catch (e) {
        engineError = 'The sound engine did not load: $e';
        startup.finish(StartupStep.engine, ok: false);
      }
      await openStorage(await ProjectStorage.open());
    } catch (e) {
      // Never stuck on the logo: show the app with whatever opened, and say why.
      openError = 'Projects could not be opened: $e';
      starting = false;
      _failUnfinishedSteps();
    } finally {
      ready = true;
      notifyListeners();
      _poller.wake();
    }
  }

  void _failUnfinishedSteps() {
    for (final step in StartupStep.values) {
      if (startup.begun(step) && !startup.done(step)) startup.finish(step, ok: false);
    }
  }

  /// Launch took longer than [StartupGate]'s limit: shows the app now, with the step still running marked failed
  /// and a line saying why. [init] carries on; if it finishes later, the project it opens replaces this one.
  void startupTimedOut() {
    if (ready || _disposed) return;
    final stuck = [for (final s in StartupStep.values) if (startup.begun(s) && !startup.done(s)) s];
    _failUnfinishedSteps();
    openError = stuck.isEmpty
        ? 'Loading took too long, so the app opened without waiting.'
        : '"${stuck.first.label}" took too long, so the app opened without waiting for it.';
    ready = true;
    notifyListeners();
    _poller.wake();
  }

  /// Reads the saved projects from [storage] and opens straight into the last one: the arrangement is home (UI
  /// plan U1). On a first run, or when the last project is gone, it opens the default project ([starterProject]). New, Template
  /// and Open are in the project menu.
  Future<void> openStorage(ProjectStorage storage) async {
    _storage = storage;
    // Each step begins when its work begins and ends when that work has ended (the startup screen shows them).
    startup.begin(StartupStep.projects);
    lastProjectId = await storage.lastOpened();
    savedProjects = await listProjects();
    if (savedProjects.isNotEmpty) startup.count(StartupStep.projects, savedProjects.length);
    final id = lastProjectId;
    ProjectDoc? last;
    NewerProjectFormat? newer;
    try {
      last = id == null ? null : await storage.load(id);
    } on NewerProjectFormat catch (e) {
      newer = e;
    }
    // A damaged file reads as null too; it stays on disk, and the app says so instead of replacing it silently.
    final damaged = newer == null && id != null && last == null && await storage.has(id);
    await loadDefaultProject(); // the bundled default: what opens without a last project, and the fallback
    await _yieldToFrames();
    final opening = last ?? starterProject();
    startup.finish(StartupStep.projects);
    await _yieldToFrames();
    // The C++ components the opening project uses that are built already, loaded one by one off the UI isolate
    // ("3/7"). One that needs building, or a Trust choice, waits until the app is open (prepareNativeComponents).
    startup.begin(StartupStep.components);
    final e = engine;
    var componentsOk = true;
    if (e != null) {
      try {
        nativeComponents = await deviceNativeComponentManager(e, storage);
      } catch (_) {
        nativeComponents = null;  // no compiler on this device: projects play without their C++ effects
        componentsOk = false;
      }
      final manager = nativeComponents;
      final total = opening.cppComponents.where((c) => c.componentId.isNotEmpty).length;
      if (manager != null && total > 0) {
        startup.count(StartupStep.components, 0, total);
        try {
          final status = await manager.prepare(opening,
              buildMissing: false, onProgress: (done) => startup.count(StartupStep.components, done, total));
          componentsOk = status.loadFailed.isEmpty;
        } catch (_) {
          componentsOk = false; // the project still opens; prepareNativeComponents tries again and says why
        }
      }
    }
    startup.finish(StartupStep.components, ok: e != null && componentsOk);
    startup.begin(StartupStep.project, project: opening.name);
    starting = false;
    String? error = damaged ? 'The last project could not be read, so the default project opened instead. '
        'Its file is still in the projects folder.' : null;
    if (newer != null) {
      error = 'The last project was saved by a newer version of C.A.W, so the default project opened instead. '
          'Its file is unchanged; update C.A.W to open it.';
    }
    try {
      await _switchTo(opening, saveCurrent: false);
    } catch (e) {
      if (last == null) rethrow;
      error = 'The last project, "${last.name}", could not be opened ($e), so the default project opened instead.';
      await _switchTo(starterProject(), saveCurrent: false);
    }
    startup.finish(StartupStep.project);
    openError = error;
  }

  /// An empty project: no modules and no layers.
  /// Settings › Projects and export sets its tempo and time signature.
  ProjectDoc blankProject() => ProjectDoc(id: newId('p'), name: 'New project')
    ..bpm = settings.newProjectBpm
    ..beatsPerBar = settings.newProjectBeatsPerBar;

  // ---------- starter content ----------

  ModuleDoc moduleFromPattern(PatternTemplate t) =>
      ModuleDoc(id: newId('m'), name: headerValue(t.source, 'name') ?? t.file.replaceAll('.caw', ''), source: t.source);

  /// The starter project: what a first run, a deleted last project and the bundled template open. A fresh copy of
  /// the owner's bundled default project ("mid tempo", 2026-11-12; [defaultProject]), read by [openStorage].
  ProjectDoc starterProject() => defaultProject();

  /// A demo project built in code, for tests and benchmarks that depend on its shape (the app's starter until
  /// 2026-11-12, "First loop"): the engine's built-in C++ instruments (#157) as kick, hats, bass, a lead, and a muted
  /// acid line and pad, each playing a pattern over the 4-bar loop; the bass, lead, acid and pad are Flagship
  /// presets (one synth, 2026-11-10). Its patterns are written here, not read from the .caw templates.
  ProjectDoc demoProject() {
    final p = ProjectDoc(id: newId('p'), name: 'First loop');
    ModuleDoc pattern(String name, String summary, String length, String notes) {
      final m = ModuleDoc(
          id: newId('m'),
          name: name,
          source: '---\ncaw: 1\nkind: pattern\nname: $name\nsummary: $summary\nlength: $length\n---\n'
              '// at = start in 16ths, len = length in 16ths, vel = 0..1\n$notes');
      p.modules.add(m);
      return m;
    }

    final kick = pattern('Kick', 'Four on the floor', '16', '0 C2 1 1\n4 C2 1 1\n8 C2 1 1\n12 C2 1 1\n');
    // F#2 is the closed hi-hat and A#2 the open one, as on a General MIDI drum kit.
    final hats = pattern('Hats', 'Hi-hats on every 16th, opening on the off-beat', '16',
        [for (var at = 0; at < 16; at++) '$at ${at % 8 == 6 ? 'A#2' : 'F#2'} 1 1\n'].join());
    final bass = pattern('Bass line', 'A minor 16th-note bass', '16',
        '0 A1 1/2 1\n2 A1 1/2 1\n3 C2 1/2 1\n4 A2 1/2 1\n6 G1 1/2 1\n8 E2 1/2 1\n9 C2 1/2 1\n11 G1 1/2 1\n'
        '12 A1 1/2 1\n15 A1 1/2 1\n');
    final lead = pattern('Lead', 'Two bars of an A minor hook', '2 bars',
        '0 E4 2 0.9\n2 A4 2 0.8\n4 C5 3 0.9\n8 B4 2 0.8\n10 A4 2 0.7\n12 G4 4 0.8\n'
        '16 E4 2 0.9\n18 A4 2 0.8\n20 C5 2 0.9\n22 D5 1 0.8 slide\n23 E5 5 0.9\n28 D5 2 0.7\n30 C5 2 0.6\n');
    final acid = pattern('Acid line', 'One bar of A minor acid with two slides, a ratchet and a note that plays half the time',
        '16',
        '// extras: slide (glide into the next note), ratchet N (repeat N times), prob P (chance it plays)\n'
        '0 A1 2 1\n2 A2 1 0.7\n3 A1 1 0.8 slide\n4 C2 2 0.9\n6 A1 1 0.6 prob 0.5\n8 E2 2 1 ratchet 2\n'
        '10 G1 1 0.7\n11 A1 1 0.8 slide\n12 A2 2 0.9\n14 G2 1 0.6\n15 E2 1 0.8\n');
    final chords = pattern('Chords', 'Four bars of A minor, F, C and G chords', '4 bars',
        '// A chord is several notes joined by commas; each note gets its own voice.\n'
        '0 A3,C4,E4 16 0.8\n16 F3,A3,C4 16 0.75\n32 C3,E3,G3 16 0.8\n48 G3,B3,D4 14 0.7\n62 G3,B3,D4 1/2 0.5 ratchet 2\n');
    var c = 0;
    void layer(String name, String instrument, ModuleDoc pattern, double vol,
        {Map<String, double> params = const {}, String? preset, List<ComponentUseDoc> effects = const [], bool mute = false}) {
      p.layers.add(LayerDoc(
          id: newId('l'),
          name: name,
          color: c++ % 4,
          instrument: ComponentUseDoc(instrument, {...params}, false, null, 1, preset),
          components: [...effects],
          clips: [ClipDoc(id: newId('c'), patternId: pattern.id, lengthSteps: p.loopSteps)],
          volume: vol,
          mute: mute));
    }

    // Both drum tracks play the 808 kit (org.caw.drums): the kick's pattern hits C2 (pad A1), the hats' F#2 and A#2.
    layer('Kick', 'org.caw.drums', kick, 0.9, preset: 'Kit: 808');
    layer('Hats', 'org.caw.drums', hats, 0.55, preset: 'Kit: 808');
    const flagship = 'org.caw.synth.flagship';
    // The filter envelope's depth: a mod slot's amount is the octaves over the cutoff knob's 9.97-octave travel.
    const cutoffOctaves = 9.965784284662087;
    layer('Bass', flagship, bass, 0.75, preset: 'Mono bass', params: {
      'flt1_cutoff': 270, 'flt1_resonance': 0.45, 'mod1_amt': 5 * 0.6 / cutoffOctaves,
      'env1_decay': 0.18, 'env2_decay': 0.18, 'env2_release': 0.18, 'env1_sustain': 0.2,
    });
    layer('Lead', flagship, lead, 0.45, preset: 'Morph pad', params: {
      'osc1_frame': 0.66, 'mod1_amt': 0.15, 'osc1_unison': 3, 'osc1_detune': 10, 'flt1_cutoff': 2600,
      'env1_attack': 0.005, 'env1_decay': 0.25, 'env1_sustain': 0.5, 'env1_release': 0.3,
    }, effects: [ComponentUseDoc('org.caw.delay', {'variant': 1, 'sync': 3, 'mix': 0.3})]);
    // Muted to start with: the acid line plays in the bass's register and the pad under the lead. Unmute one.
    layer('Acid', flagship, acid, 0.6, preset: 'Acid 303',
        params: {'flt1_resonance': 0.8}, effects: [ComponentUseDoc('org.caw.drive', {'drive': 3, 'mix': 0.5})], mute: true);
    layer('Pad', flagship, chords, 0.5, preset: 'Morph pad', effects: [ComponentUseDoc('org.caw.chorus')], mute: true);
    return p;
  }

  // ---------- engine sync and saving ----------

  /// The layer a pattern's note previews play on: the selected layer if it plays [patternId], else the first that
  /// does; null when no layer plays it.
  String? previewLayerFor(String patternId) {
    bool plays(LayerDoc l) => l.instrument != null && (l.patternId == patternId || l.clips.any((c) => c.patternId == patternId));
    final selected = project.layers.where((l) => l.id == selectedLayerId && plays(l)).firstOrNull;
    return (selected ?? project.layers.where(plays).firstOrNull)?.id;
  }

  /// Where the engine rendered at [timeNs] on the MIDI clock, in steps (not moved back to what was heard): the
  /// tap-along calibration compares it with the beat. Null when the engine can't tell.
  double? renderStepAt(int timeNs) {
    final e = engine;
    final m = meters;
    if (e == null || timeNs <= 0 || m.loopLength <= 0) return null;
    final pos = e.positionAt(timeNs);
    return pos < 0 ? null : project.stepAtLoopFraction(pos / m.loopLength);
  }

  /// The tip the latency badge shows while the output adds more than 50 ms; null otherwise.
  String? get latencyTip => latency.outputIsLate
      ? '${latency.routeInfo.output.label} adds ${latency.outputMs.round()} ms: live playing and monitoring will feel late'
      : null;

  /// What Solo preview plays for the selected pattern: its notes through the C++ instrument and effects of a track
  /// that plays it; null when no track with an instrument plays it.
  ({String pattern, ComponentUseDoc instrument, List<ComponentUseDoc> components})? get preview {
    final m = project.module(selectedModuleId);
    if (m == null || !isPattern(m.id)) return null;
    final layer = project.layers.where((l) =>
        !l.isFolder && l.instrument != null && l.clips.any((clip) => clip.patternId == m.id)).firstOrNull;
    if (layer == null) return null;
    return (pattern: m.id, instrument: layer.instrument!, components: layer.components);
  }

  /// [p]'s engine JSON as the project sync sends it, without the preview: a track render (freeze and bounce,
  /// lib/model/freeze.dart) plays a copy of the project through it.
  String engineJsonOf(ProjectDoc p) => _engineJson(of: p, preview: false);

  String _engineJson({Map<String, String>? sourceOverrides, ProjectDoc? of, bool preview = true}) {
    final pv = previewOnly && preview ? this.preview : null;
    final project = of ?? this.project;
    return project.toEngineJson(
        auditionPattern: pv?.pattern,
        auditionInstrument: pv?.instrument,
        auditionComponents: pv?.components ?? const [],
        auditionOnly: previewOnly && preview,
        voices: settings.lightMode ? 4 : 32, // global cap; each generator chooses its own voice count
        swap: settings.swapTiming.name,
        suspendLanes: suspendedLanes,
        // The engine's built-ins (org.caw.*) are always loaded, so they play beside the project's loaded ones.
        playableComponents: nativeComponents == null ? null : {
          ...nativeComponents!.loaded,
          for (final c in [
            ...project.masterComponents,
            for (final l in project.layers) ...[...l.components, ?l.instrument],
          ])
            if (c.id.startsWith('org.caw.')) c.id,
        },
        sourceOverrides: sourceOverrides);
  }

  Future<void> _syncNow() async {
    final e = engine;
    if (e == null) return;
    _livePending = null; // the project as it is now supersedes a drag step not yet sent
    _docGen++;
    // What a sync can change that the screens show: listeners hear of it only when one of these differs (an edit
    // already notified when it was made; a sync with the same result rebuilds nothing; beta plan B4.4).
    final before = (info: info, error: engineError, warnings: e.lastProjectWarnings, on: _transportOn,
        id: _engineProjectId);
    final json = _engineJson();
    final id = project.id;
    try {
      info = await e.setProject(json);
      engineError = null;
      _engineProjectId = id;
      pushTempo();
    } catch (err) {
      engineError = 'Engine error: $err';
      // The engine keeps what it had when a project is refused. That is right for an edit of this project (its last
      // good state plays on), but never for another project: its audio must not play under this one's name.
      if (_engineProjectId != id) {
        e.stop();
        _transportOn = false;
        try {
          info = await e.setProject(ProjectDoc(id: id, name: project.name).toEngineJson());
          _engineProjectId = id;
        } catch (_) {
          // Even the empty project was refused: leave the transport stopped.
        }
      }
    }
    if (!mapEquals(before.info, info) || before.error != engineError || before.on != _transportOn ||
        before.id != _engineProjectId || !listEquals(before.warnings, e.lastProjectWarnings)) {
      notifyListeners();
    }
  }

  /// Sends the project to the engine soon, with no edit (the automation writer after [suspendedLanes] changes).
  void resyncEngine() => _sync();

  /// A pattern edit still under the finger, heard while the song plays (#170): the project goes to the engine with
  /// [text] as pattern [moduleId]'s source, so a sounding note follows the drag. Nothing else changes: no save, no
  /// undo step, and no listener is notified (the piano roll keeps its drag in an overlay). The roll throttles calls
  /// to about 30 a second; one sent while another is still being built waits, and only the newest is sent.
  /// [text] null (a drag cancelled) sends the project as it is again.
  Future<void> livePattern(String moduleId, String? text) async {
    if (engine == null) return;
    _livePending = (id: moduleId, text: text);
    if (!_liveBusy) await _liveSend();
  }

  static const _liveMarker = '\u0001caw-live-source\u0001';

  /// Bumped by every edit, value move and engine sync of the project (never by a selection, the transport or
  /// meters): screens keep parts built from the project (Arrange's track headers and clips) while it stays the same.
  int get docGen => _docGen;

  /// The engine JSON of a live drag step: the project with [text] as module [moduleId]'s source.
  @visibleForTesting
  String liveEngineJson(String moduleId, String text) {
    var t = _liveTemplate;
    if (t == null || t.gen != _docGen || !identical(t.project, project) || t.id != moduleId) {
      final json = _engineJson(sourceOverrides: {moduleId: _liveMarker});
      final marker = jsonEncode(_liveMarker);
      final at = json.indexOf(marker);
      if (at < 0 || json.indexOf(marker, at + 1) >= 0) return _engineJson(sourceOverrides: {moduleId: text});
      t = _liveTemplate = (gen: _docGen, project: project, id: moduleId, head: json.substring(0, at),
          tail: json.substring(at + marker.length));
    }
    return '${t.head}${jsonEncode(text)}${t.tail}';
  }

  Future<void> _liveSend() async {
    _liveBusy = true;
    try {
      for (var next = _livePending; next != null; next = _livePending) {
        _livePending = null;
        final e = engine;
        if (e == null || _disposed) break;
        final text = next.text;
        if (text == null) {
          _syncTimer?.cancel();
          await _syncNow();
          continue;
        }
        try {
          await e.setProject(liveEngineJson(next.id, text));
        } catch (_) {
          // A live step that fails (the engine busy or gone) is dropped: the edit is sent in full on release.
        }
      }
    } finally {
      _liveBusy = false;
    }
  }

  /// Sends the project to the engine soon (edits in quick succession are sent once).
  void _sync() {
    _docGen++;
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(milliseconds: 40), _syncNow);
  }

  void _save() {
    _docGen++;
    _recordHistory();
    _saveTimer?.cancel();
    _saveTimer = Timer(Duration(milliseconds: settings.autosaveMs), flush);
  }

  /// Lets the frames waiting to be drawn go first (launch work runs between the startup reveal's frames).
  static Future<void> _yieldToFrames() => Future<void>.delayed(Duration.zero);
}
