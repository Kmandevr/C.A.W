// The music video editor's model: the #183 note unroll, auto-cut triggers, snapping, lane and list edits, layout
// geometry, the effect stack, pitch bends, falling notes, and saving with the project (versioned, older projects load).
import 'dart:convert';
import 'dart:typed_data';

import 'package:caw/model/music_video.dart';
import 'package:caw/model/music_video_autocut.dart';
import 'package:caw/model/music_video_director.dart';
import 'package:caw/model/music_video_edit.dart';
import 'package:caw/model/music_video_meters.dart';
import 'package:caw/model/music_video_scene.dart';
import 'package:caw/model/project.dart';
import 'package:caw/ui/music_video/video_painter.dart';
import 'package:flutter_test/flutter_test.dart';

const _quarters = '---\ncaw: 1\nkind: pattern\nname: Q\nlength: 1 bar\n---\n0 C4 1 1\n4 D4 1 1\n8 E4 1 1\n12 F4 1 1\n';
const _held = '---\ncaw: 1\nkind: pattern\nname: H\nlength: 1 bar\n---\n2 C4 4 1\n8 E4 2 1\n';

VideoScene _sceneOf(List<ClipDoc> clips, {String source = _quarters}) => buildVideoScene(
    ProjectDoc(id: 'p', name: 'p', bpm: 120, loopBars: 4, modules: [ModuleDoc(id: 'm', name: 'M', source: source)],
        layers: [LayerDoc(id: 't', name: 'T', color: 0, clips: clips)]),
    colorOf: (_) => 0xffffffff);

void main() {
  group('#183 notes in the arrangement shot', () {
    test('a looped clip with a source offset shows the notes after the loop wraps, as the engine plays them', () {
      // The engine plays source steps 4..16 at 0..12, wraps to 0..16 at 12..28, then 0..4 at 28..32.
      final s = _sceneOf([ClipDoc(id: 'c', patternId: 'm', lengthSteps: 32, sourceOffsetSteps: 4, loop: true)]);
      expect([for (final n in s.notes) n.start], [0, 4, 8, 12, 16, 20, 24, 28]);
      expect([for (final n in s.notes) n.pitch], [62, 64, 65, 60, 62, 64, 65, 60]);
    });

    test('a note already sounding where the clip starts in its source is kept from there (its tail)', () {
      final s = _sceneOf([ClipDoc(id: 'c', patternId: 'm', lengthSteps: 12, sourceOffsetSteps: 4, loop: false)], source: _held);
      expect([for (final n in s.notes) (n.start, n.end, n.pitch)], [(0.0, 2.0, 60.0), (4.0, 6.0, 64.0)]);
    });

    test('a clip that does not loop plays its source once and stops at the pattern end', () {
      final s = _sceneOf([ClipDoc(id: 'c', patternId: 'm', lengthSteps: 32, loop: false)]);
      expect([for (final n in s.notes) n.start], [0, 4, 8, 12]);
    });
  });

  group('snapping', () {
    test('steps, beats and the project bar', () {
      expect(snapStep(5.4, VideoSnap.step, 16), 5);
      expect(snapStep(5.9, VideoSnap.beat, 16), 4);
      expect(snapStep(6.1, VideoSnap.beat, 16), 8);
      expect(snapStep(23, VideoSnap.bar, 16), 16);
      expect(snapStep(25, VideoSnap.bar, 16), 32);
      // A 3/4 bar is twelve steps.
      expect(snapStep(19, VideoSnap.bar, 12), 24);
      expect(VideoSnap.bar.grid(12), 12);
    });
  });

  group('lane edits', () {
    VideoTimeline lane() => VideoTimeline([
          VideoCut(id: 's1', start: 0, length: 16),
          VideoCut(id: 's2', start: 16, length: 16, layout: VideoLayout.single(VideoShot.mixer)),
          VideoCut(id: 's3', start: 48, length: 16),
        ]);
    const bar = VideoSnap.bar, beat = VideoSnap.beat;

    test('gaps, add in a gap only, and new ids never repeat', () {
      final t = lane();
      expect(t.gaps(0, 64), [(32.0, 48.0)]);
      expect(t.gaps(0, 80), [(32.0, 48.0), (64.0, 80.0)]);
      expect(t.add(5, snap: bar, stepsPerBar: 16, hi: 64), isNull); // inside a shot
      final made = t.add(37, snap: beat, stepsPerBar: 16, hi: 64)!;
      expect((made.start, made.length), (36.0, 12.0)); // a bar, cut short by the next shot
      expect(t.cuts.map((c) => c.id).toSet().length, 4);
      expect(made.id, 's4');
    });

    test('move keeps the length, snaps, and stays between its neighbours', () {
      final t = lane();
      expect(t.move('s3', 41, snap: beat, stepsPerBar: 16, hi: 80), isTrue);
      expect(t.byId('s3')!.start, 40);
      expect(t.move('s3', 0, snap: beat, stepsPerBar: 16, hi: 80), isTrue);
      expect(t.byId('s3')!.start, 32); // stops at s2's end
      t.move('s3', 999, snap: beat, stepsPerBar: 16, hi: 80);
      expect(t.byId('s3')!.end, 80); // and at the range's end
      expect(t.byId('s3')!.length, 16);
    });

    test('trims move one edge; a cut marker moves both shots', () {
      final t = lane();
      t.trimEnd('s2', 40, snap: beat, stepsPerBar: 16, hi: 64);
      expect(t.byId('s2')!.end, 40);
      t.trimEnd('s2', 60, snap: beat, stepsPerBar: 16, hi: 64);
      expect(t.byId('s2')!.end, 48); // not past s3
      t.trimStart('s3', 44, snap: beat, stepsPerBar: 16, hi: 64);
      expect(t.byId('s3')!.start, 48); // not before s2's end
      t.trimStart('s3', 60, snap: beat, stepsPerBar: 16, hi: 64);
      expect((t.byId('s3')!.start, t.byId('s3')!.end), (60.0, 64.0));
      expect(t.cutMarkers(), [1]); // s1|s2 touch; s2|s3 don't
      final u = lane();
      expect(u.moveCut(1, 9, snap: beat, stepsPerBar: 16), isTrue);
      expect((u.cuts[0].end, u.cuts[1].start, u.cuts[1].end), (8.0, 8.0, 32.0));
      u.moveCut(1, -50, snap: beat, stepsPerBar: 16);
      expect(u.cuts[0].length, kVideoMinShotSteps); // never folds a shot away
    });

    test('split, delete, duplicate with ripple, and the list span', () {
      final t = lane();
      final right = t.split('s1', 9, snap: beat, stepsPerBar: 16)!;
      expect((t.byId('s1')!.end, right.start, right.end), (8.0, 8.0, 16.0));
      expect(t.split('s1', 12, snap: beat, stepsPerBar: 16), isNull); // outside it now
      expect(t.delete('s1'), isTrue);
      expect(t.gaps(0, 64).first, (0.0, 8.0));
      final d = lane();
      final dup = d.duplicate('s2', hi: 64)!;
      expect((dup.start, dup.length, dup.layout.panels.first.view), (32.0, 16.0, VideoShot.mixer));
      expect(d.byId('s3'), isNull); // pushed past the end: dropped
      final e = lane();
      expect(e.setSpan('s3', start: 36, length: 8, snap: beat, stepsPerBar: 16, hi: 64), isTrue);
      expect((e.byId('s3')!.start, e.byId('s3')!.length), (36.0, 8.0));
    });

    test('fill only the empty space keeps the edits', () {
      final t = lane();
      final fresh = [for (var i = 0; i < 8; i++) VideoCut(id: 'a$i', start: i * 8.0, length: 8)];
      final added = t.fillGaps(fresh, 0, 64);
      expect(added, 2);
      expect(t.cuts.where((c) => c.start >= 32 && c.end <= 48).length, 2);
      expect(t.byId('s2')!.layout.panels.first.view, VideoShot.mixer);
      t.replaceAll(fresh);
      expect(t.cuts.length, 8);
    });
  });

  group('layouts', () {
    test('each preset covers the frame once, its dividers move and stay off the edges', () {
      for (final p in VideoLayoutPreset.values) {
        final l = VideoLayout(preset: p);
        final rects = l.rects();
        expect(rects.length, p.panels);
        expect(l.panels.length, p.panels);
        final area = rects.fold(0.0, (a, r) => a + r.width * r.height);
        expect(area, closeTo(1, 1e-9), reason: p.name);
      }
      final big = VideoLayout(preset: VideoLayoutPreset.bigStrip);
      expect(big.rects().first.height, closeTo(0.76, 1e-9)); // the arrangement takes most of the frame
      expect([for (final p in big.panels) p.view], [VideoShot.flythrough, VideoShot.mixer]);
      final grid = VideoLayout(preset: VideoLayoutPreset.grid);
      grid.setSplit(0, 0.3);
      grid.setSplit(1, 0.99);
      expect(grid.rects()[3], const PanelRect(0.3, VideoLayout.maxSplit, 1, 1));
      expect(grid.dividers().map((d) => d.vertical), [true, false]);
      // Changing the preset keeps the views in order and fills the new places.
      final kept = VideoLayout(preset: VideoLayoutPreset.sideBySide,
          panels: [VideoPanel(view: VideoShot.falling), VideoPanel(view: VideoShot.devices)]).withPreset(VideoLayoutPreset.grid);
      expect([for (final p in kept.panels) p.view],
          [VideoShot.falling, VideoShot.devices, VideoShot.flythrough, VideoShot.mixer]);
      expect(PanelRect.lerp(const PanelRect(0, 0, 1, 1), const PanelRect(0, 0, 0.5, 0.5), 0.5), const PanelRect(0, 0, 0.75, 0.75));
    });
  });

  group('effects', () {
    test("an effect's strength follows its drive", () {
      const loud = VideoLevels(rms: 0.2, tracks: {'lead': 0.5});
      final steady = VideoEffect(kind: VideoEffectKind.glow, amount: 0.6);
      expect(steady.strength(3.3, VideoLevels.silent, 16), closeTo(0.6, 1e-12));
      final beat = VideoEffect(kind: VideoEffectKind.punch, amount: 1, drive: VideoDrive.beat, decay: 0.5);
      expect(beat.strength(4, VideoLevels.silent, 16), 1); // on the beat
      expect(beat.strength(5, VideoLevels.silent, 16), closeTo(0.25, 1e-12)); // half way through its pulse
      expect(beat.strength(6.5, VideoLevels.silent, 16), 0); // after it
      final bar = VideoEffect(kind: VideoEffectKind.strobe, amount: 1, drive: VideoDrive.bar);
      expect(bar.strength(16, VideoLevels.silent, 16), 1);
      expect(bar.strength(4, VideoLevels.silent, 16), closeTo(0.25, 1e-12));
      expect(VideoEffect(kind: VideoEffectKind.blur, amount: 1, drive: VideoDrive.master).strength(0, loud, 16), closeTo(0.5, 1e-12));
      final track = VideoEffect(kind: VideoEffectKind.shake, amount: 1, drive: VideoDrive.track, trackId: 'lead');
      expect(track.strength(0, loud, 16), closeTo(0.7, 1e-12));
      expect((track..trackId = 'none').strength(0, loud, 16), 0);
      expect((steady..on = false).strength(0, loud, 16), 0);
    });
  });

  group('pitch bends', () {
    test('a note keeps its bend and vibrato through the clip, and the pitch range takes them in', () {
      const bent = '---\ncaw: 1\nkind: pattern\nname: B\nlength: 1 bar\n---\n0 C4 4 1 bend 0:0 1:5\n8 E4 2 1 vib 0.5 6\n';
      final s = _sceneOf([ClipDoc(id: 'c', patternId: 'm', lengthSteps: 16, loop: false)], source: bent);
      expect(s.notes.map((n) => n.bends), [true, true]);
      expect(s.notes.first.bendAt(0, 120), 0);
      expect(s.notes.first.bendAt(1, 120), 5);
      expect(s.notes.first.bendAt(0.5, 120), closeTo(2.5, 1e-9));
      final (lo, hi) = s.pitchRange();
      expect(lo, closeTo(60, 1e-9));
      expect(hi, closeTo(65, 1e-9));
      expect(_sceneOf([ClipDoc(id: 'c', patternId: 'm', lengthSteps: 16)]).notes.any((n) => n.bends), isFalse);
    });

    test('a trimmed clip keeps the part of the bend it plays', () {
      const bent = '---\ncaw: 1\nkind: pattern\nname: B\nlength: 1 bar\n---\n0 C4 8 1 bend 0:0 1:8\n';
      final s = _sceneOf([ClipDoc(id: 'c', patternId: 'm', lengthSteps: 4, sourceOffsetSteps: 4, loop: false)], source: bent);
      expect((s.notes.single.start, s.notes.single.end), (0.0, 4.0));
      expect(s.notes.single.bendAt(0, 120), closeTo(4, 1e-6)); // half way up the bend where the clip starts
      expect(s.notes.single.bendAt(1, 120), closeTo(8, 1e-6));
    });
  });

  group('falling notes', () {
    test("the keyboard fits the song's notes, or all 88 keys; a hidden track leaves the range", () {
      final s = _two();
      final shot = planFromTimeline(s, VideoTimeline([VideoCut(id: 's1', start: 0, length: 64,
          layout: VideoLayout.single(VideoShot.falling))]), MusicVideoOptions(), start: 0, end: 64).shots.single;
      final (lo, hi) = videoKeyboardRange(shot);
      expect(lo, lessThanOrEqualTo(36)); // the bass's C2
      expect(hi, greaterThanOrEqualTo(72)); // the lead's C5
      expect([lo, hi].any((p) => const [1, 3, 6, 8, 10].contains(p % 12)), isFalse); // white keys at the ends
      final hidden = planFromTimeline(s, VideoTimeline([VideoCut(id: 's1', start: 0, length: 64,
          layout: VideoLayout(panels: [VideoPanel(view: VideoShot.falling, hiddenTracks: {'bass'})]))]),
          MusicVideoOptions(), start: 0, end: 64).shots.single;
      expect(videoKeyboardRange(hidden).$1, greaterThan(48));
      final full = planFromTimeline(s, VideoTimeline([VideoCut(id: 's1', start: 0, length: 64,
          layout: VideoLayout(panels: [VideoPanel(view: VideoShot.falling, fullKeyboard: true)]))]),
          MusicVideoOptions(), start: 0, end: 64).shots.single;
      expect(videoKeyboardRange(full), (21, 108));
      final kb = VideoKeyboard(21, 108, 520);
      expect(kb.whites, 52);
      final (bl, br) = kb.span(22); // A#0 straddles A0 and B0
      expect(bl < kb.whiteWidth && br > kb.whiteWidth, isTrue);
      expect(kb.centerX(60.5), closeTo((kb.centerX(60) + kb.centerX(61)) / 2, 1e-9));
    });

    test('the director picks Falling notes only when it is switched on', () {
      final s = _two();
      for (var seed = 1; seed <= 5; seed++) {
        expect(directVideo(s, MusicVideoOptions(seed: seed), start: 0, end: 64).shots.any((x) => x.kind == VideoShot.falling), isFalse);
      }
      final only = directVideo(s, MusicVideoOptions(shots: {VideoShot.falling}), start: 0, end: 64);
      expect(only.shots.every((x) => x.kind == VideoShot.falling), isTrue);
    });
  });

  group('plan from the lane', () {
    test('shots in place, gaps as the arrangement, panels as views, stems when a view or effect needs them', () {
      final s = _two();
      final t = VideoTimeline([
        VideoCut(id: 's1', start: 16, length: 16, layout: VideoLayout(preset: VideoLayoutPreset.bigStrip),
            transition: VideoTransition.crossfade, transitionSteps: 4, animateLayout: true),
      ]);
      final plan = planVideo(s, MusicVideoOptions(), t, start: 0, end: 64);
      expect([for (final x in plan.shots) (x.start, x.end, x.kind)],
          [(0.0, 16.0, VideoShot.flythrough), (16.0, 32.0, VideoShot.flythrough), (32.0, 64.0, VideoShot.flythrough)]);
      expect(plan.shots[1].panelShots.map((p) => p.kind), [VideoShot.flythrough, VideoShot.mixer]);
      expect(plan.shots[1].edited, isTrue);
      expect(plan.shots[0].edited, isFalse);
      expect(planNeedsStems(plan), isTrue); // the mixer strip
      final noMixer = planVideo(s, MusicVideoOptions(), VideoTimeline([VideoCut(id: 's1', start: 0, length: 64,
          effects: [VideoEffect(kind: VideoEffectKind.glow, drive: VideoDrive.track, trackId: 'lead')])]), start: 0, end: 64);
      expect(planNeedsStems(noMixer), isTrue);
      expect(planNeedsStems(planVideo(s, MusicVideoOptions(), VideoTimeline([VideoCut(id: 's1', start: 0, length: 64)]),
          start: 0, end: 64)), isFalse);
      // An empty lane is the auto director's.
      expect(planVideo(s, MusicVideoOptions(seed: 3), VideoTimeline(), start: 0, end: 64).shots.join(),
          directVideo(s, MusicVideoOptions(seed: 3), start: 0, end: 64).shots.join());
    });
  });

  group('auto-cut', () {
    test('every N bars or beats, on the song grid', () {
      final s = _two();
      expect(intervalCuts(s, 0, 64, count: 1, bars: true).map((c) => c.step), [16, 32, 48]);
      expect(intervalCuts(s, 0, 16, count: 2, bars: false).map((c) => c.step), [8]);
      expect(intervalCuts(s, 20, 64, count: 2, bars: true).map((c) => c.step), [32]);
    });

    test('note bursts cut where notes come thick after a thinner beat; sensitivity sets how many', () {
      final s = _two(); // the lead plays eight notes in a beat from bar 3 (step 32); before, one a beat
      final cuts = burstCuts(s, 0, 64, notes: AutoCutSettings(burstSensitivity: 0.5).burstNotes);
      expect(cuts.map((c) => c.step), [32]);
      expect(burstCuts(s, 0, 64, notes: 20), isEmpty);
      expect(AutoCutSettings(burstSensitivity: 0).burstNotes, 12);
      expect(AutoCutSettings(burstSensitivity: 1).burstNotes, 3);
    });

    test('tracks coming in and going quiet', () {
      final s = _two(); // the bass plays bars 1..2, rests in bar 3, plays bar 4; the lead comes in at bar 3
      final cuts = trackCuts(s, 0, 64, quietBeats: 4);
      expect(cuts.map((c) => (c.step, c.reason)), containsAll([
        (32.0, 'Bass goes quiet'), (32.0, 'Lead comes in'), (48.0, 'Bass comes in'),
      ]));
      expect(trackCuts(s, 0, 64, quietBeats: 8).where((c) => c.step == 48), isEmpty); // a bar's rest isn't two
    });

    test('loudness jumps from the notes or from the rendered audio', () {
      final s = _two();
      final fromNotes = loudnessCuts(s, 0, 64, noteLoudness(s, 64), db: 6);
      expect(fromNotes.map((c) => c.step), contains(32.0));
      expect(fromNotes.firstWhere((c) => c.step == 32).reason, startsWith('Drop'));
      // Rendered audio: quiet for two bars, loud for two (4 s at 120 bpm, 20 fps).
      const fps = 20;
      final frames = 160;
      final rms = Float32List.fromList([for (var i = 0; i < frames; i++) i < 80 ? 0.02 : 0.5]);
      final m = OfflineVideoMeters(frames: frames, peakL: rms, peakR: rms, rms: rms, tracks: const {});
      final db = audioLoudness(m, fps: fps, bpm: 120, start: 0, end: 64);
      expect(db[0], closeTo(20 * 0.30103 * -5.64, 1)); // about −34 dB
      final cuts = loudnessCuts(s, 0, 64, db, db: 12);
      expect(cuts.map((c) => (c.step, c.reason.split(' ').first)), [(32.0, 'Drop')]);
      expect(loudnessCuts(s, 0, 64, db, db: 40), isEmpty);
    });

    test('merged cuts keep the stronger trigger and the minimum gap; shots cover the range', () {
      final merged = mergeCuts([
        (step: 16, trigger: CutTrigger.interval, reason: 'i'),
        (step: 20, trigger: CutTrigger.loudness, reason: 'l'),
        (step: 40, trigger: CutTrigger.burst, reason: 'b'),
      ], 0, 64, minSteps: 8);
      expect(merged.map((c) => c.step), [20, 40]);
      final s = _two();
      final shots = autoCut(s, AutoCutSettings(), MusicVideoOptions(seed: 2), start: 0, end: 64);
      expect(shots.first.start, 0);
      expect(shots.last.end, 64);
      for (var i = 1; i < shots.length; i++) {
        expect(shots[i].start, shots[i - 1].end);
        expect(shots[i].reason, isNotEmpty);
      }
      expect(shots.map((c) => c.start), contains(32.0));
      // The same in the background isolate.
      expect(autoCut(s, AutoCutSettings(), MusicVideoOptions(seed: 2), start: 0, end: 64).map((c) => jsonEncode(c.toJson())),
          shots.map((c) => jsonEncode(c.toJson())));
      final none = autoCut(s, AutoCutSettings(interval: false, bursts: false, tracks: false, loudness: false),
          MusicVideoOptions(), start: 0, end: 64);
      expect(none.length, 1);
    });

    test('in a background isolate it gives the same shots', () async {
      final s = _two();
      final here = autoCut(s, AutoCutSettings(), MusicVideoOptions(seed: 4), start: 0, end: 64);
      final there = await autoCutInBackground(s, AutoCutSettings(), MusicVideoOptions(seed: 4), start: 0, end: 64);
      expect(there.map((c) => jsonEncode(c.toJson())), here.map((c) => jsonEncode(c.toJson())));
    });
  });

  group('review fixes', () {
    const beat = VideoSnap.beat;

    test('a shot past the range end: trims refuse instead of throwing, and nothing changes', () {
      final t = VideoTimeline([VideoCut(id: 's1', start: 0, length: 16), VideoCut(id: 's2', start: 300, length: 20)]);
      expect(t.trimEnd('s2', 340, snap: beat, stepsPerBar: 16, hi: 256), isFalse);
      expect(t.setSpan('s2', length: 24, snap: beat, stepsPerBar: 16, hi: 256), isFalse);
      expect((t.byId('s2')!.start, t.byId('s2')!.length), (300.0, 20.0));
      // A shot whose start edge has no room after the range's start.
      final u = VideoTimeline([VideoCut(id: 's1', start: 0, length: 8)]);
      expect(u.trimStart('s1', 4, snap: beat, stepsPerBar: 16, lo: 16, hi: 64), isFalse);
      expect(u.byId('s1')!.start, 0);
    });

    test('duplicate pushes only the shots inside the range and leaves those past its end alone', () {
      final t = VideoTimeline([
        VideoCut(id: 's1', start: 0, length: 16),
        VideoCut(id: 's2', start: 16, length: 16),
        VideoCut(id: 's3', start: 80, length: 16), // past the range (0..64): never pushed
      ]);
      final dup = t.duplicate('s1', hi: 64)!;
      expect(dup.start, 16);
      expect((t.byId('s2')!.start, t.byId('s2')!.end), (32.0, 48.0));
      expect((t.byId('s3')!.start, t.byId('s3')!.end), (80.0, 96.0));
    });

    test('replacing a range keeps the shots outside it, and the outside parts of shots across its edges', () {
      final t = VideoTimeline([
        VideoCut(id: 's1', start: 0, length: 40), // across the range's start (32)
        VideoCut(id: 's2', start: 48, length: 8),
        VideoCut(id: 's3', start: 120, length: 16), // across its end (128)
        VideoCut(id: 's4', start: 200, length: 16), // outside
      ]);
      t.replaceRange([VideoCut(id: 'a0', start: 32, length: 64), VideoCut(id: 'a1', start: 96, length: 32)], 32, 128);
      expect([for (final c in t.cuts) (c.start, c.end)],
          [(0.0, 32.0), (32.0, 96.0), (96.0, 128.0), (128.0, 136.0), (200.0, 216.0)]);
      expect(t.byId('s1')!.end, 32);
      expect(t.byId('s4')!.start, 200);
      expect(t.cuts.map((c) => c.id).toSet().length, 5);
    });

    test('a dense clip over the note cap keeps the notes up to the cap', () {
      // 64 notes a bar for 3,200 bars: 204,800 notes, past the 200,000 cap.
      final dense = StringBuffer('---\ncaw: 1\nkind: pattern\nname: D\nlength: 1 bar\n---\n');
      for (var i = 0; i < 64; i++) {
        dense.write('${i / 4} C4 0.25 1\n');
      }
      final s = _sceneOf([ClipDoc(id: 'c', patternId: 'm', lengthSteps: 16 * 3200)], source: dense.toString());
      expect(s.notes.length, kSceneMaxNotes);
      expect(s.clips.single.notes.length, kSceneMaxNotes);
    });

    test('the notes sounding over a span, through the interval index, with a whole-song drone', () {
      const src = '---\ncaw: 1\nkind: pattern\nname: N\nlength: 64 bars\n---\n0 C2 1024 1\n';
      final p = ProjectDoc(id: 'p', name: 'p', bpm: 120, loopBars: 64, modules: [
        ModuleDoc(id: 'drone', name: 'Drone', source: src),
        ModuleDoc(id: 'm', name: 'M', source: _quarters),
      ], layers: [
        LayerDoc(id: 'a', name: 'A', color: 0, clips: [ClipDoc(id: 'd', patternId: 'drone', lengthSteps: 1024, loop: false)]),
        LayerDoc(id: 'b', name: 'B', color: 1, clips: [ClipDoc(id: 'q', patternId: 'm', lengthSteps: 1024)]),
      ]);
      final s = buildVideoScene(p, colorOf: (_) => 0xffffffff);
      for (final (a, b) in [(0.0, 4.0), (500.5, 532.0), (17.0, 17.5), (1000.0, 1100.0), (63.9, 64.1)]) {
        final brute = {for (var i = 0; i < s.notes.length; i++) if (s.notes[i].start < b && s.notes[i].end > a) i};
        final got = s.notesSounding(a, b).toList();
        expect(got.toSet(), brute, reason: '$a..$b');
        expect(got.length, got.toSet().length, reason: 'each note once');
      }
      // The drone doesn't make a frame walk the whole song: few notes are looked at past the span's bucket.
      expect(s.notesSounding(500, 501).length, 2); // the drone and the quarter note there
    });

    test("the keyboard's spans: white keys side by side, each black key across a white key's edge", () {
      final kb = VideoKeyboard(21, 108, 520);
      var x = 0.0;
      for (var p = 21; p <= 108; p++) {
        final (l, r) = kb.span(p);
        if (const [1, 3, 6, 8, 10].contains(p % 12)) {
          final edge = (l + r) / 2;
          expect((edge / kb.whiteWidth - (edge / kb.whiteWidth).round()).abs(), lessThan(1e-9));
        } else {
          expect(l, closeTo(x, 1e-9));
          x = r;
        }
      }
      expect(x, closeTo(520, 1e-9));
    });
  });

  group("owner's follow-ups", () {
    test('an effect can target one panel; a panel the layout lost means the whole shot; it saves', () {
      final e = VideoEffect(kind: VideoEffectKind.blur, panel: 1);
      expect(e.panelIn(2), 1);
      expect(e.panelIn(1), isNull); // a full layout: the whole shot
      expect(e.panelIn(4), 1);
      expect(VideoEffect(kind: VideoEffectKind.blur, panel: 3).panelIn(2), isNull);
      expect(VideoEffect(kind: VideoEffectKind.blur).panelIn(4), isNull);
      final back = VideoEffect.fromJson(jsonDecode(jsonEncode(e.toJson())))!;
      expect(back.panel, 1);
      expect(VideoEffect.fromJson({'kind': 'blur', 'panel': 9})!.panel, isNull);
      expect(VideoEffect(kind: VideoEffectKind.strobe).flashes, isTrue);
    });

    test('a new video has Falling notes when the song has notes; saved setups keep their shots', () {
      expect(VideoShot.forNewVideo(hasNotes: true), {...VideoShot.directorDefaults, VideoShot.falling});
      expect(VideoShot.forNewVideo(hasNotes: false), VideoShot.directorDefaults);
      final saved = MusicVideoDoc.fromJson({'version': 1, 'options': {'shots': ['mixer']}});
      expect(saved.options.shots, {VideoShot.mixer});
    });

    testWidgets('a panel effect changes only its panel', (tester) async {
      final s = _two();
      Future<List<int>> frame(List<VideoEffect> fx) async {
        final cut = VideoCut(id: 's1', start: 0, length: 64, effects: fx, layout: VideoLayout(
            preset: VideoLayoutPreset.sideBySide, panels: [VideoPanel(view: VideoShot.flythrough), VideoPanel(view: VideoShot.falling)]));
        final plan = planFromTimeline(s, VideoTimeline([cut]), MusicVideoOptions(), start: 0, end: 64);
        return (await tester.runAsync(() => rasterizeVideoFrame(
            VideoFrameInput(scene: s, plan: plan, step: 33, seconds: 4), 128, 64)))!.toList();
      }

      // The difference between two frames in the left and right halves (bytes that differ).
      (int, int) diff(List<int> a, List<int> b) {
        var l = 0, r = 0;
        for (var i = 0; i < a.length; i += 4) {
          if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) ((i ~/ 4) % 128 < 64) ? l++ : r++;
        }
        return (l, r);
      }

      final none = await frame([]);
      final right = await frame([VideoEffect(kind: VideoEffectKind.tint, amount: 1, panel: 1)]);
      final whole = await frame([VideoEffect(kind: VideoEffectKind.tint, amount: 1)]);
      final (rl, rr) = diff(none, right);
      expect(rl, 0); // the left panel is untouched
      expect(rr, greaterThan(100));
      final (wl, wr) = diff(none, whole);
      expect(wl, greaterThan(100));
      expect(wr, greaterThan(100));
    });
  });

  group('saving', () {
    test('the video saves with the project and reads back', () {
      final doc = MusicVideoDoc(options: MusicVideoOptions(style: VideoStyle.calm, seed: 9, shots: {VideoShot.falling},
          aspect: VideoAspect.square, smoothFollow: true, title: 'T'), snap: VideoSnap.bar)
        ..timeline.cuts.addAll([
          VideoCut(id: 's1', start: 0, length: 16, layout: VideoLayout(preset: VideoLayoutPreset.grid, split: 0.3, panels: [
            VideoPanel(view: VideoShot.falling, look: VideoLook(palette: VideoPalette.cool, noteStyle: VideoNoteStyle.line,
                grid: false, glow: 1.5, background: VideoBackground.gradient), fullKeyboard: true, hiddenTracks: {'bass'}, bars: 4),
          ]), effects: [VideoEffect(kind: VideoEffectKind.tint, amount: 0.3, drive: VideoDrive.track, trackId: 'lead',
              color: VideoEffectColor.violet, decay: 0.2, on: false)],
              transition: VideoTransition.push, transitionSteps: 8, animateLayout: true, zoom: 1.5, reason: 'Drop'),
        ])
        ..autoCut = AutoCutSettings(intervalCount: 2, intervalBars: false, burstSensitivity: 0.9, fromAudio: true);
      final p = ProjectDoc(id: 'p', name: 'p')..musicVideo = doc.toJson();
      final back = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      final read = MusicVideoDoc.fromJson(back.musicVideo);
      expect(jsonEncode(read.toJson()), jsonEncode(doc.toJson()));
      expect(back.musicVideo!['version'], MusicVideoDoc.version);
      expect(read.timeline.cuts.single.layout.panels.length, 4);
      expect(read.timeline.newId(), 's2');
    });

    test('an older project (no music video) loads as a new video; damaged and newer files load what they can', () {
      final old = ProjectDoc.fromJson({'id': 'p', 'name': 'Old', 'caw_app_project': 2, 'layers': []});
      expect(old.musicVideo, isNull);
      final fresh = MusicVideoDoc.fromJson(old.musicVideo);
      expect(fresh.timeline.isEmpty, isTrue);
      expect(fresh.options.shots, VideoShot.directorDefaults);
      expect(old.toJson().containsKey('music_video'), isFalse); // saving doesn't add one until it's edited
      final odd = MusicVideoDoc.fromJson({
        'version': 7,
        'future_field': {'x': 1},
        'options': {'fps': 999, 'aspect': [0, 'x'], 'style': 'wild', 'shots': ['falling', 'laser']},
        'shots': [
          {'id': 's1', 'start': 0, 'length': 32, 'layout': {'preset': 'grid', 'split': 9, 'panels': [{'view': 'nope'}]},
            'effects': [{'kind': 'lens-flare'}, {'kind': 'glow', 'amount': 7}, 'junk']},
          {'id': 's1', 'start': 16, 'length': 8}, // overlaps: dropped
          {'id': 's1', 'start': 40, 'length': 8}, // a repeated id: renamed
          {'start': 'x'},
          {'id': 'big', 'start': -5, 'length': double.maxFinite},
        ],
        'snap': 'nonsense',
      }, maxStep: 4096);
      expect(odd.options.fps, 30);
      expect(odd.options.style, VideoStyle.energetic);
      expect(odd.options.shots, {VideoShot.falling});
      final cuts = odd.timeline.cuts;
      expect(cuts.first.layout.split, VideoLayout.maxSplit);
      expect(cuts.first.layout.panels.length, 4);
      expect(cuts.first.layout.panels.first.view, VideoShot.flythrough);
      expect(cuts.first.effects.map((e) => (e.kind, e.amount)), [(VideoEffectKind.glow, 1.0)]);
      expect(cuts.map((c) => c.id).toSet().length, cuts.length);
      expect(cuts.every((c) => c.end <= 4096 + 1e-9), isTrue);
      expect(odd.snap, VideoSnap.beat);
    });
  });

  group('frames', () {
    testWidgets("an edited shot draws deterministically; effects and looks change it", (tester) async {
      final s = _two();
      Future<String> frame(VideoCut c, {double step = 33}) async {
        final plan = planFromTimeline(s, VideoTimeline([c]), MusicVideoOptions(), start: 0, end: 64);
        final bytes = await tester.runAsync(() => rasterizeVideoFrame(
            VideoFrameInput(scene: s, plan: plan, step: step, seconds: 4, levels: const VideoLevels(rms: 0.3)), 96, 160));
        return base64Encode(bytes!);
      }

      VideoCut cut({VideoLayout? layout, List<VideoEffect>? fx}) =>
          VideoCut(id: 's1', start: 0, length: 64, layout: layout, effects: fx);
      final plain = await frame(cut());
      for (final k in VideoEffectKind.values) {
        final a = await frame(cut(fx: [VideoEffect(kind: k, amount: 1)]), step: 32);
        final b = await frame(cut(fx: [VideoEffect(kind: k, amount: 1)]), step: 32);
        expect(a, b, reason: '${k.name} is deterministic');
        expect(a, isNot(await frame(cut(), step: 32)), reason: '${k.name} changes the frame');
      }
      final looked = await frame(cut(layout: VideoLayout(panels: [VideoPanel(view: VideoShot.flythrough,
          look: VideoLook(palette: VideoPalette.mono, background: VideoBackground.black))])));
      expect(looked, isNot(plain));
      for (final p in VideoLayoutPreset.values) {
        expect(await frame(cut(layout: VideoLayout(preset: p))), isNotEmpty);
      }
      final falling = await frame(cut(layout: VideoLayout.single(VideoShot.falling)));
      expect(falling, await frame(cut(layout: VideoLayout.single(VideoShot.falling))));
      expect(falling, isNot(plain));
    });
  });
}

const _bass = '---\ncaw: 1\nkind: pattern\nname: Bass\nlength: 4 bars\n---\n0 C2 2 1\n4 C2 2 1\n8 C2 2 1\n12 C2 2 1\n'
    '16 C2 2 1\n20 C2 2 1\n24 C2 2 1\n28 C2 2 1\n48 C2 2 1\n52 C2 2 1\n56 C2 2 1\n60 C2 2 1\n';
const _lead = '---\ncaw: 1\nkind: pattern\nname: Lead\nlength: 2 bars\n---\n'
    '0 C4 0.5 1\n0.5 D4 0.5 1\n1 E4 0.5 1\n1.5 F4 0.5 1\n2 G4 0.5 1\n2.5 A4 0.5 1\n3 B4 0.5 1\n3.5 C5 0.5 1\n'
    '4 C4 4 1\n8 E4 4 1\n12 G4 4 1\n16 C4 4 1\n20 E4 4 1\n24 G4 4 1\n28 C4 4 1\n';

/// Four bars: the bass in bars 1, 2 and 4, a bar's rest in bar 3; the lead from bar 3, opening with a run of eight.
VideoScene _two() => buildVideoScene(ProjectDoc(id: 'p', name: 'p', bpm: 120, loopBars: 4, modules: [
      ModuleDoc(id: 'bass', name: 'Bass', source: _bass), ModuleDoc(id: 'lead', name: 'Lead', source: _lead),
    ], layers: [
      LayerDoc(id: 'bass', name: 'Bass', color: 0, clips: [ClipDoc(id: 'b', patternId: 'bass', lengthSteps: 64, loop: false)]),
      LayerDoc(id: 'lead', name: 'Lead', color: 1, clips: [ClipDoc(id: 'l', patternId: 'lead', startSteps: 32, lengthSteps: 32, loop: false)]),
    ]), colorOf: (l) => 0xff40ffc0 + l.color);
