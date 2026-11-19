// The bundled chain templates (Guitar clean, crunch and lead; Vocal; Podcast voice; Drum bus; Master): built-in effects from their engine presets, listed by purpose in the effect browser.
import 'app_state.dart';
import 'arrange_fx.dart';
import 'device_names.dart';
import 'project.dart';

/// One effect of a chain template: a built-in and the engine preset it starts from (null: its defaults).
class ChainStep {
  const ChainStep(this.componentId, [this.preset]);
  final String componentId;
  final String? preset;
}

/// A ready-made chain: its [steps] in order, the [purposes] it shows under, and a one-line [summary].
class ChainTemplate {
  const ChainTemplate(this.id, this.name, this.summary, this.purposes, this.steps);
  final String id, name, summary;
  final Set<DevicePurpose> purposes;
  final List<ChainStep> steps;
}

const _talon = 'org.caw.compressor', _canopy = 'org.caw.limiter', _hatch = 'org.caw.gate', _duck = 'org.caw.duck',
    _ember = 'org.caw.drive', _plume = 'org.caw.eq', _relay = 'org.caw.delay', _roost = 'org.caw.reverb',
    _hollow = 'org.caw.convolver', _flutter = 'org.caw.chorus', _glint = 'org.caw.exciter', _quell = 'org.caw.deesser',
    _wingspan = 'org.caw.utility', _preen = 'org.caw.clean', _hush = 'org.caw.vocalclean', _lookout = 'org.caw.meters',
    _swoop = 'org.caw.transient';

class ChainTemplates {
  ChainTemplates._();

  /// Every bundled chain template (sound plan, "Around the effects").
  static const all = <ChainTemplate>[
    ChainTemplate('chain:guitar-clean', 'Guitar clean', 'Quiet hum, even sustain, a clean amp and cab, a little width and room',
        {DevicePurpose.guitar}, [
      ChainStep(_hatch, 'Guitar hum down'), ChainStep(_talon, 'Guitar sustain'), ChainStep(_ember, 'Clean jazz amp'),
      ChainStep(_hollow, 'Open back clean'), ChainStep(_flutter, 'Subtle thicken'), ChainStep(_roost, 'Guitar amp room'),
    ]),
    ChainTemplate('chain:guitar-crunch', 'Guitar crunch', 'A classic crunch amp into a close 4x12, the mud tamed',
        {DevicePurpose.guitar}, [
      ChainStep(_hatch, 'Guitar hum down'), ChainStep(_ember, 'Classic crunch'), ChainStep(_hollow, 'Rock 4x12 close'),
      ChainStep(_plume, 'Guitar mud tamer'), ChainStep(_roost, 'Guitar amp room'),
    ]),
    ChainTemplate('chain:guitar-lead', 'Guitar lead', 'A gated high-gain lead with a 2x12, an echo and a plate',
        {DevicePurpose.guitar}, [
      ChainStep(_hatch, 'High-gain guitar'), ChainStep(_ember, 'Blues lead'), ChainStep(_hollow, '2x12 lead'),
      ChainStep(_relay, 'Space echo'), ChainStep(_roost, 'Guitar plate'),
    ]),
    ChainTemplate('chain:vocal', 'Vocal', 'Pops out, presence up, even level, soft esses, air and a plate',
        {DevicePurpose.vocals}, [
      ChainStep(_hush, 'Pop filter'), ChainStep(_plume, 'Vocal presence'), ChainStep(_talon, 'Vocal detail'),
      ChainStep(_quell, 'Vocal'), ChainStep(_glint, 'Vocal air'), ChainStep(_roost, 'Vocal plate'),
    ]),
    ChainTemplate('chain:podcast-voice', 'Podcast voice', 'Clean, clear speech at an even level, with a ceiling',
        {DevicePurpose.vocals}, [
      ChainStep(_preen, 'Voice clean-up'), ChainStep(_hush, 'Podcast voice'), ChainStep(_hatch, 'Podcast clean'),
      ChainStep(_plume, 'Vocal presence'), ChainStep(_quell, 'Vocal'), ChainStep(_duck, 'Podcast rider'),
      ChainStep(_canopy),
    ]),
    ChainTemplate('chain:drum-bus', 'Drum bus', 'Punch, a little grit, the boom in check and a ceiling',
        {DevicePurpose.drums, DevicePurpose.mixing}, [
      ChainStep(_swoop), ChainStep(_talon, 'Drum bus punch'), ChainStep(_ember, 'Drum bus grit'),
      ChainStep(_plume, 'Boom control'), ChainStep(_canopy),
    ]),
    ChainTemplate('chain:master', 'Master', 'Low end held, glue, polish, width, a ceiling and a loudness meter',
        {DevicePurpose.mastering}, [
      ChainStep(_plume, 'Master low end hold'), ChainStep(_talon, 'Master glue'), ChainStep(_glint, 'Master polish'),
      ChainStep(_wingspan, 'Master widen'), ChainStep(_canopy), ChainStep(_lookout, 'Streaming -14 LUFS'),
    ]),
  ];

  static ChainTemplate? byId(String id) => all.where((t) => t.id == id).firstOrNull;

  static List<ChainTemplate> forPurpose(DevicePurpose p) => [for (final t in all) if (t.purposes.contains(p)) t];
}

extension ChainTemplateEdits on AppState {
  /// The values [step] starts with: its engine preset's (a merged device's `variant` included), else none (the
  /// defaults).
  Map<String, double> chainStepValues(ChainStep step) {
    final name = step.preset;
    if (name == null) return {};
    final preset = componentInfo(step.componentId)?.presets.where((p) => p.name == name).firstOrNull;
    return {...?preset?.params};
  }

  /// Adds [t]'s effects to the end of [layer]'s chain, as one undo step. False when nothing could be added (a
  /// frozen track, a folder without a bus, a full chain).
  bool applyChainTemplate(LayerDoc layer, ChainTemplate t) {
    endUndoStep();
    var added = 0;
    for (final step in t.steps) {
      final use = ComponentUseDoc(step.componentId, chainStepValues(step))..autoGain = settings.autoGainNewDevices;
      if (insertNativeEffect(layer, use) == null) break;
      added++;
    }
    endUndoStep();
    return added > 0;
  }
}
