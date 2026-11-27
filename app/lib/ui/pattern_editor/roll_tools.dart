// The pattern editor's tools: generators, vibrato, the quantize sheet, step input, hearing notes, the context menu, the extras panel and MIDI import and export.
// ignore_for_file: invalid_use_of_protected_member
part of '../pattern_editor.dart';

extension _RollTools on _PatternEditorState {
  // ---------- generators ----------

  /// Asks for a generator's settings, then applies it as one undo step. Euclid and Random write from the cursor at the
  /// grid size; the others work on the selection.
  Future<void> _generate(String id) async {
    final d = _doc;
    if (d == null) return;
    final bar = Steps(s.project.beatsPerBar * 4);
    final seed = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
    final v = await showDialogOrSheet<Map<String, double>>(
      context: context,
      builder: (_) => RollGenDialog(id: id, rate: _resSteps),
    );
    if (v == null || !mounted || _doc == null) return;
    final doc = _doc!;
    switch (id) {
      case 'roll.gen.euclid':
        final r = doc.euclid(
            at: _cursorAt,
            pulses: v['pulses']!.round(),
            steps: v['steps']!.round(),
            rotate: v['rotate']!.round(),
            cell: _resSteps,
            pitch: _cursorPitch);
        _apply(r.doc, select: r.ids);
      case 'roll.gen.random':
        final range = v['range']!.round();
        final r = doc.randomInKey(
            at: _cursorAt,
            span: bar.times(v['bars']!.round()),
            cell: _resSteps,
            lo: (_cursorPitch - range).round(),
            hi: (_cursorPitch + range).round(),
            density: v['density']! / 100,
            key: _key,
            seed: seed);
        _apply(r.doc, select: r.ids);
      case 'roll.gen.arpeggiate':
        final r = doc.arpeggiate(_sel, _resSteps, order: const ['up', 'down', 'updown'][v['order']!.round()]);
        _apply(r.doc, select: r.ids);
      case 'roll.gen.humanize':
        _apply(doc.humanize(_sel, timing: v['timing']! / 100, velocity: v['velocity']! / 100, seed: seed));
      case 'roll.gen.chordStamp':
        final r = doc.chordStamp(_sel, key: _key, seventh: v['seventh']! > 0);
        _apply(r.doc, select: {..._sel, ...r.ids});
      case 'roll.gen.connect':
        _apply(doc.connect(_sel, glide: v['glide']! / 100));
      case 'roll.gen.tremolo':
        final wave = TremoloWave.values[v['wave']!.round()];
        final cycle = rollTremoloCycles[v['cycle']!.round()];
        final depth = v['depth']! / 100;
        final sel = _sel.isEmpty ? {for (final n in doc.notes) n.id} : _sel;
        if (v['mode']!.round() == 1) {
          final r = doc.tremoloRepeat(sel, rate: _resSteps, cycle: cycle, depth: depth, wave: wave);
          _apply(r.doc, select: r.ids);
        } else {
          _apply(doc.tremolo(sel, cycle: cycle, depth: depth, wave: wave));
        }
    }
  }

  /// Vibrato (owner, 2026-11-11): sets the selected notes' own vibrato (every note when none is selected), the same
  /// values the extras panel's vibrato sliders show; their bend curves stay. A synced rate is turned into Hz at the
  /// project's tempo when it is applied. One undo step; repeatable (no randomness).
  Future<void> _vibrato() async {
    final d = _doc;
    if (d == null || d.notes.isEmpty) return;
    final v = await showDialogOrSheet<RollVibrato>(
      context: context,
      builder: (_) => RollVibratoDialog(secPerStep: _secPerStep),
    );
    final doc = _doc;
    if (v == null || !mounted || doc == null) return;
    final sel = _sel.isEmpty ? {for (final n in doc.notes) n.id} : _sel;
    _apply(doc.setVibrato(sel, depth: v.cents / 100, rate: v.hz(_secPerStep), fade: v.fade));
  }

  // ---------- the quantize sheet (REAPER flow gap 8; REAPER's Quantize events, UG 13.23) ----------

  /// Opens the sheet; the roll shows (and, while playing, plays) each setting as it moves, and Apply makes it one
  /// undo step. Cancel or a swipe away puts the notes back. No selection: every note.
  Future<void> _quantizeSheet() async {
    final base = _doc;
    if (base == null) return;
    final sel = _sel.isEmpty ? {for (final n in base.notes) n.id} : _sel;
    final seed = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
    PatternDoc result(RollQuantize q) => base.quantizeWith(sel, q.grid,
        strength: q.strength, swing: q.swing, what: q.what, humanTiming: q.timing, humanVelocity: q.velocity, seed: seed);
    void preview(RollQuantize? q) {
      if (!mounted) return;
      final next = q == null ? base : result(q);
      setState(() => _doc = next);
      _live(next);
    }

    final q = await showDialogOrSheet<RollQuantize>(
      context: context,
      builder: (_) => RollQuantizeSheet(res: _res, triplet: _triplet, count: sel.length, onPreview: preview),
    );
    if (!mounted) return;
    final sent = _liveEnd();
    setState(() => _doc = base);
    if (q == null) {
      if (sent) s.livePattern(widget.module.id, null);
      return;
    }
    _apply(result(q));
    if (sent) _flush();
  }

  void _stepToggle() {
    setState(() => _step = !_step);
    Haptics.tap();
    _stepMidi?.cancel();
    _stepMidi = null;
    _stepHeld.clear();
    _stepKeysOff();
    if (!_step) return;
    final live = LiveMidi.current;
    _stepMidi = live?.input?.messages.listen((m) {
      if (!mounted || !_step || !live.accepts(m)) return;
      if (m.isNoteOn) _stepNoteOn(m.data1, m.data2 / 127);
      if (m.isNoteOff) _stepHeld.remove(m.data1);
    });
  }

  /// A note played: a new step when no other key is down (the cursor moves on), else part of the held chord.
  void _stepNoteOn(int pitch, double vel) {
    final d = _doc;
    if (d == null) return;
    final len = _resSteps;
    if (_stepHeld.isEmpty) {
      _stepChordAt = _cursorAt;
      _stepAdvance(len);
    }
    _stepHeld.add(pitch);
    _cursorPitch = pitch.toDouble();
    final r = d.insert(_stepChordAt, pitch.toDouble(), len, vel: vel);
    if (r.id != null) {
      final chord = {for (final n in r.doc.notes) if (n.at == _stepChordAt && _sel.contains(n.id)) n.id};
      _apply(r.doc, select: {...chord, r.id!});
    }
    Haptics.tick();
  }

  /// Moves the step cursor on by [by], scrolling so it stays in view.
  void _stepAdvance(Steps by) {
    setState(() {
      _cursorAt = _cursorAt + by;
      final x = _cursorAt.toDouble() * _pxPerStep - _scrollX;
      if (_gridW > 0 && (x > _gridW - 48 || x < 0)) _scrollX = math.max(0.0, _cursorAt.toDouble() * _pxPerStep - _gridW / 3);
    });
  }

  void _stepKeysOff() {
    for (final k in _stepKeys.values) {
      if (k.preview != null) s.previewOff(k.preview!);
    }
    _stepKeys.clear();
  }

  /// A finger or click on the roll's keys during step input: the note sounds while held and goes in.
  void _stepKeyDown(PointerDownEvent e, double y) {
    final pitch = _pitchAt(y).clamp(0, 127).round();
    final layer = _hearLayer;
    int? pid;
    if (layer != null) {
      pid = s.nextPreviewId();
      s.previewOn(layer, pid, pitch.toDouble(), _lastVel);
    }
    _stepKeys[e.pointer] = (pitch: pitch, preview: pid);
    _stepNoteOn(pitch, _lastVel);
  }

  void _stepKeyUp(int pointer) {
    final k = _stepKeys.remove(pointer);
    if (k == null) return;
    if (k.preview != null) s.previewOff(k.preview!);
    if (!_stepKeys.values.any((o) => o.pitch == k.pitch)) _stepHeld.remove(k.pitch);
  }

  /// The step input bar under the toolbar: where the next note goes, Rest and Done.
  Widget _stepBar() {
    final bar = s.project.beatsPerBar * 4;
    final at = _cursorAt.toDouble();
    final pos = '${at ~/ bar + 1}.${(at % bar) ~/ 4 + 1}.${formatNumber(((at % 4) * 1000).roundToDouble() / 1000 + 1)}';
    return Container(
      key: const ValueKey('roll-step-bar'),
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: Neon.pink.withValues(alpha: 0.12),
      child: Row(children: [
        const Icon(Icons.piano, size: 16, color: Neon.pink),
        const SizedBox(width: 6),
        Expanded(
          child: Text('STEP INPUT · next at $pos · ${noteLengthLabel(_resSteps)}',
              overflow: TextOverflow.ellipsis, style: const TextStyle(color: Neon.pink, fontSize: 11, letterSpacing: 0.8)),
        ),
        Pressable(child: TextButton(onPressed: () => _runRef(const ActionRef.action('roll.step.rest')), child: const Text('Rest'))),
        Pressable(child: TextButton(onPressed: () => _runRef(const ActionRef.action('roll.step.toggle')), child: const Text('Done'))),
      ]),
    );
  }

  String? get _hearLayer => _look.hearNotes ? s.previewLayerFor(widget.module.id) : null;

  /// Starts [ids]' previews (ending any before): of several notes, those that start first.
  void _hear(Iterable<int> ids) {
    _hearStop();
    final d = _doc, layer = _hearLayer;
    if (d == null || layer == null) return;
    final notes = [for (final id in ids) ?d.byId(id)];
    if (notes.isEmpty) return;
    final first = notes.map((n) => n.at).reduce(Steps.min);
    for (final n in notes) {
      if (n.at != first) continue;
      final pid = s.nextPreviewId();
      s.previewOn(layer, pid, n.pitch, n.vel);
      _heard[n.id] = (id: pid, pitch: n.pitch);
    }
  }

  /// After a move: a note whose pitch changed ends and starts again at its new pitch; a move in time doesn't.
  void _hearFollow() {
    final d = _doc, layer = _hearLayer;
    if (d == null || layer == null) return;
    for (final entry in _heard.entries.toList()) {
      final n = d.byId(entry.key);
      if (n == null || n.pitch == entry.value.pitch) continue;
      s.previewOn(layer, entry.value.id, n.pitch, n.vel);
      _heard[entry.key] = (id: entry.value.id, pitch: n.pitch);
    }
  }

  /// While a pitch point is dragged the note sounds at that point's pitch; on a segment, at the curve under the finger.
  void _hearBendAt(Offset p) {
    final id = _bNote, d = _dragBase ?? _doc, layer = _hearLayer;
    if (id == null || d == null || layer == null) return;
    final n = d.byId(id);
    if (n == null) return;
    final pts = _curveView.value.points ?? n.expr.bend, i = _bPoint;
    final pitch = (n.pitch +
            (i != null && i < pts.length
                ? pts[i].v
                : NoteExpression.valueAt(pts, ((p.dx - _noteX(n)) / _noteW(n)).clamp(0.0, 1.0))))
        .clamp(0.0, 127.0)
        .toDouble();
    final h = _heard[id];
    if (h == null) {
      _hearStop();
      final pid = s.nextPreviewId();
      s.previewOn(layer, pid, pitch, n.vel);
      _heard[id] = (id: pid, pitch: pitch);
    } else if (h.pitch != pitch) {
      s.previewPitch(h.id, pitch);
      _heard[id] = (id: h.id, pitch: pitch);
    }
  }

  void _hearStop() {
    _tapOff?.cancel();
    _tapOff = null;
    for (final h in _heard.values) {
      s.previewOff(h.id);
    }
    _heard.clear();
  }

  /// The extras panel for the selected notes, in sections with the most used first (owner, 2026-11-11): velocity
  /// and chance; ratchet with its ramp and the brush; slide; tremolo and vibrato; then the note's own expression.
  /// One undo step for the whole visit.
  Future<void> _openExtras() async {
    final base = _doc;
    if (base == null || _sel.isEmpty) return;
    final sel = Set<int>.of(_sel);
    String? then; // an action to run once the sheet has closed (a tool or a dialog)
    await showGlassSheet<void>(
      context: context,
      backgroundColor: Neon.panel,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final n = _doc!.byId(sel.first)!;
        void change(PatternDoc Function(PatternDoc) f) {
          setState(() => _doc = f(_doc!));
          set(() {});
        }

        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(sel.length == 1 ? 'Note at ${n.at}, length ${n.len}' : '${sel.length} notes',
                style: const TextStyle(color: Neon.text)),
            const Heading('Note'),
            ValueSlider(
                label: 'Velocity',
                value: n.vel,
                min: 0,
                max: 1,
                reset: 1,
                scale: 100,
                unit: '%',
                onChanged: (v) => change((d) => d.setVelocity(sel, _lastVel = v))),
            // Chance steps by the value grid while snapping is on, like the chance lane.
            ValueSlider(
                label: 'Chance',
                value: n.prob,
                min: 0,
                max: 1,
                reset: 1,
                scale: 100,
                unit: '%',
                divisions: _snap ? (1 / _look.valueGrid.step).round() : null,
                onChanged: (v) => change((d) => d.setProb(sel, v))),
            const Heading('Ratchet'),
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (var r = 1; r <= kPatternMaxRatchet; r++)
                ChoiceChip(
                  label: Text('$r'),
                  selected: n.ratchet == r,
                  onSelected: (_) => change((d) => d.setRatchet(sel, r)),
                ),
            ]),
            if (sel.any((id) => (_doc!.byId(id)?.ratchet ?? 1) > 1)) ...[
              // The engine plays a ratchet's repeats at one velocity: a ramp writes them out as notes.
              Text('Ramp the repeats (writes them out as notes)', style: TextStyle(color: Neon.dim, fontSize: 12)),
              ValueSlider(
                  label: 'Ramp depth',
                  value: _rampDepth,
                  min: 0,
                  max: 1,
                  reset: 0.7,
                  scale: 100,
                  unit: '%',
                  onChanged: (v) => set(() => _rampDepth = v)),
              Wrap(spacing: 6, children: [
                for (final (ramp, name) in const [(RatchetRamp.fadeIn, 'Fade in'), (RatchetRamp.fadeOut, 'Fade out')])
                  ActionChip(
                    key: ValueKey('ratchet-ramp-${ramp.name}'),
                    label: Text(name),
                    onPressed: () => change((d) {
                      final r = d.ratchetRamp(sel, ramp: ramp, depth: _rampDepth);
                      sel
                        ..clear()
                        ..addAll(r.ids);
                      _sel = {...sel};
                      return r.doc;
                    }),
                  ),
              ]),
            ],
            TextButton.icon(
              onPressed: () {
                then = 'roll.tool.ratchet';
                Navigator.pop(ctx);
              },
              icon: const Icon(Icons.view_week_outlined, size: 18),
              label: const Text('Ratchet brush (drag over notes)'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Slide'),
              value: n.slide,
              onChanged: (v) => change((d) => d.setSlide(sel, v)),
            ),
            const Heading('Wobble'),
            Wrap(spacing: 6, children: [
              for (final (id, name) in const [('roll.gen.tremolo', 'Tremolo…'), ('roll.gen.vibrato', 'Vibrato…')])
                ActionChip(
                  label: Text(name),
                  onPressed: () {
                    then = id;
                    Navigator.pop(ctx);
                  },
                ),
            ]),
            // The note's own pitch curve, vibrato, volume and timbre (MPE style); one undo step with the rest.
            ExpressionPanel(
              expr: n.expr,
              color: _noteColor,
              // A shared expression edit has no single note duration to snap against.
              timeSnap: _snap && sel.length == 1 ? _resSteps.toDouble() / n.len.toDouble() : 0,
              valueSnap: _snap ? _look.valueGrid.step : 0,
              onChanged: (e) => change((d) => d.setExpression(sel, e)),
            ),
          ]),
          ),
        );
      }),
    );
    if (!mounted) return;
    if (!identical(base, _doc)) {
      _pushUndo(_Undo(base));
      setState(() {});
      _scheduleSend();
    }
    final next = then;
    if (next != null) _action(next, 1, null);
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  /// Replaces the notes with a MIDI file's (one undo step); the file's tempo isn't applied.
  /// ⋮ Import MIDI file: a .mid through the app's own converter (`lib/model/midi_clips.dart`, on another isolate),
  /// replacing the notes; a file of several parts comes in as one pattern with all of them.
  Future<void> _importMidi() async {
    try {
      final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['mid', 'midi']);
      if (f == null) return;
      if (await f.xFile.length() > kMaxMidiFileBytes) throw const MidiFileException('the file is bigger than 16 MB');
      final bytes = await f.xFile.readAsBytes();
      final beats = s.project.beatsPerBar;
      final m = await Isolate.run(() => midiImport(bytes, beatsPerBar: beats));
      if (m.clips.isEmpty) throw const FormatException('the file has no notes');
      final current = _doc;
      if (current == null) return;
      // The pattern keeps its own name and header; its notes become the file's, every part together, and its
      // length the longest part's.
      var doc = current.delete({for (final n in current.notes) n.id});
      var steps = 1;
      for (final c in m.clips) {
        final r = PatternDoc.parse(c.source);
        if (!r.ok) throw FormatException(r.error ?? 'unreadable pattern');
        doc = doc.paste(PatternClip(r.doc!.notes, Steps.zero), Steps.zero).doc;
        steps = math.max(steps, r.doc!.lengthSteps(beats));
      }
      doc = doc.setLength(steps: steps);
      _apply(doc, select: {});
      _say('Imported ${doc.notes.length} notes');
    } on FormatException catch (e) {
      _say('Not imported: ${e.message}');
    } catch (e) {
      _say('Could not import: $e');
    }
  }

  Future<void> _exportMidi({required bool clip}) async {
    _flush();
    final d = _doc;
    if (d == null) return;
    final name = '${widget.module.name}.${clip ? 'midi2' : 'mid'}';
    try {
      final Uint8List bytes;
      if (clip) {
        // MIDI 2.0 clips still come from the engine's converter.
        final dir = await getTemporaryDirectory();
        final path = '${dir.path}${Platform.pathSeparator}caw-export-${DateTime.now().microsecondsSinceEpoch}';
        final source = d.serialize(), bpm = s.project.bpm.toDouble(), beats = s.project.beatsPerBar;
        // The engine's converter writes the file: off the UI isolate, as the exporter does.
        final err = await Isolate.run(() => Engine.exportPattern(source, path, bpm: bpm, beatsPerBar: beats, clip: true));
        if (err != null) throw Exception(err);
        final file = File(path);
        bytes = await file.readAsBytes();
        await file.delete();
      } else {
        // A Standard MIDI File from the app's own converter, as a clip's export makes (MPE when notes are bent).
        bytes = patternToMidi(d, bpm: s.project.bpm.toDouble(), beatsPerBar: s.project.beatsPerBar, name: widget.module.name);
      }
      final saved = await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: 'audio/midi');
      _say(saved == null ? 'Not exported (picker closed).' : 'Exported $name');
    } catch (e) {
      _say('Could not export: $e');
    }
  }
}
