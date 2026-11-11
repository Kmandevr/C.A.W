// The fx-space effects' display floats (layouts in docs/engine.md, "Display data") decoded into frames, and their browser entries.
import 'device_display.dart';

/// The fx-space effects, in browser order.
const fxSpaceIds = [
  'org.caw.convolver', 'org.caw.shimmer', 'org.caw.haas', 'org.caw.ensemble', 'org.caw.doubler', 'org.caw.vibrato',
  'org.caw.tremolo', 'org.caw.autopan', 'org.caw.rotary', 'org.caw.imager', 'org.caw.channelmixer',
];

/// What the effect browser shows of an effect: its category tab (Space, Modulation, Utility, ...) and one line.
class FxBrowserEntry {
  const FxBrowserEntry(this.category, this.description);
  final String category, description;
}

/// The browser entries of the fx-space effects (the browser's icon comes from the editor registry).
const fxSpaceBrowser = <String, FxBrowserEntry>{
  'org.caw.convolver': FxBrowserEntry('Space', 'Convolution reverb: generated rooms, halls, plates and springs, or your own WAV'),
  'org.caw.shimmer': FxBrowserEntry('Space', 'A reverb whose tail climbs an octave or a fifth each round'),
  'org.caw.haas': FxBrowserEntry('Space', 'Width from delaying one side a few milliseconds, with a mono check'),
  'org.caw.ensemble': FxBrowserEntry('Modulation', 'Up to eight detuned chorus voices spread across the field'),
  'org.caw.doubler': FxBrowserEntry('Modulation', 'Double-tracking: late, slightly detuned copies panned wide'),
  'org.caw.vibrato': FxBrowserEntry('Modulation', 'Pitch wobble in cents, free or in time'),
  'org.caw.tremolo': FxBrowserEntry('Modulation', 'Level wobble in seven shapes, classic or harmonic'),
  'org.caw.autopan': FxBrowserEntry('Modulation', 'Moves the sound from side to side in time with the song'),
  'org.caw.rotary': FxBrowserEntry('Modulation', 'A spinning horn and drum: the Leslie organ speaker'),
  'org.caw.imager': FxBrowserEntry('Utility', 'Width per band, mid and side gain, a correlation meter and vectorscope'),
  'org.caw.channelmixer': FxBrowserEntry('Utility', 'Route, swap, fold or invert the left and right channels'),
};

/// The frame of an fx-space effect, or null for any other component.
DeviceDisplayFrame? decodeFxSpaceDisplay(String id, List<double> f, int n) {
  double at(int i) => i < n ? f[i] : 0;
  Map<String, double> named(List<String> names, int from) =>
      {for (var i = 0; i < names.length && from + i < n; ++i) names[i]: f[from + i]};
  DeviceDisplayFrame frame(Map<String, double> values) => DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: values);
  switch (id) {
    case 'org.caw.ensemble':
      return frame({...named(['voices', 'depth_ms', 'lfo'], 2), for (var v = 0; v < 8 && 5 + v < n; ++v) 'voice$v': f[5 + v]});
    case 'org.caw.doubler':
      return frame({...named(['count'], 2), for (var v = 0; v < 4 && 3 + v < n; ++v) 'double$v': f[3 + v]});
    case 'org.caw.vibrato':
      return frame(named(['lfo_l', 'lfo_r', 'rate_hz', 'depth_ms'], 2));
    case 'org.caw.tremolo':
    case 'org.caw.autopan':
      return frame(named(['lfo_l', 'lfo_r', 'gain_l', 'gain_r', 'rate_hz'], 2));
    case 'org.caw.rotary':
      return frame(named(['horn_angle', 'drum_angle', 'horn_hz', 'drum_hz'], 2));
    case 'org.caw.haas':
      return frame(named(['correlation', 'mono_loss_db', 'delay_ms', 'notch_hz', 'mono'], 2));
    case 'org.caw.channelmixer':
      return frame(named(['correlation', 'balance'], 2));
    case 'org.caw.imager':
      final points = at(8).toInt();
      return frame({
        ...named(['correlation', 'balance', 'corr_low', 'corr_mid', 'corr_high', 'mono_loss_db'], 2),
        for (var p = 0; p < points && 10 + 2 * p < n; ++p) ...{'m$p': f[9 + 2 * p], 's$p': f[10 + 2 * p]},
      });
    case 'org.caw.convolver':
      final points = at(8).toInt();
      return frame({
        ...named(['wet_db', 'latency_ms', 'ir_s', 'built', 'source', 'file'], 2),
        for (var p = 0; p < points && 9 + p < n; ++p) 'env$p': f[9 + p],
      });
    case 'org.caw.shimmer':
      return frame(named(['wet_db', 'shimmer_db', 'semitones', 'decay_s', 'size'], 2));
    default:
      return null;
  }
}
