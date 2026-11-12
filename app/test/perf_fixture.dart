// A big project for the performance benchmarks: the demo project (the code-built First loop) grown to 16 tracks, with long patterns, many clips,
// native effects and automation lanes, so per-edit work scales the way a real song's would.
import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';

/// The demo project, plus tracks until there are [tracks]: each new one plays its own 4-bar pattern of [notes] notes
/// in [clips] clips, with an effect and a volume lane.
ProjectDoc bigProject(AppState s, {int tracks = 16, int notes = 64, int clips = 8}) {
  final p = s.demoProject();
  final instruments = ['org.caw.synth.morph', 'org.caw.bass', 'org.caw.synth.acid', 'org.caw.synth.morph'];
  for (var t = p.layers.length; t < tracks; t++) {
    final lines = StringBuffer('---\ncaw: 1\nkind: pattern\nname: Line $t\nlength: 4 bars\n---\n');
    for (var n = 0; n < notes; n++) {
      lines.writeln('${n % 64} ${['A2', 'C3', 'E3', 'G3', 'B3'][n % 5]} 1 ${0.5 + (n % 5) / 10}');
    }
    final m = ModuleDoc(id: 'pm$t', name: 'Line $t', source: lines.toString());
    p.modules.add(m);
    p.layers.add(LayerDoc(
      id: 'pl$t',
      name: 'Track $t',
      color: t % 8,
      instrument: ComponentUseDoc(instruments[t % instruments.length], {'cutoff': 1200.0 + t}),
      components: [ComponentUseDoc('org.caw.delay.pingpong', {'sync': 3, 'mix': 0.2})],
      clips: [
        for (var c = 0; c < clips; c++) ClipDoc(id: 'pc$t-$c', patternId: m.id, startSteps: c * 64, lengthSteps: 64),
      ],
      automation: [
        AutomationLaneDoc(target: 'volume', points: [
          for (var i = 0; i < 32; i++) AutomationPointDoc(step: i * 16.0, value: (i % 4) / 4),
        ]),
      ],
    ));
  }
  return p;
}
