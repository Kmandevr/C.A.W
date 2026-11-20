// Timber's Simulated piano in the app (1.1.2): a new Timber starts Simulated; changing to another instrument and back starts afresh; the same id keeps its values.
import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a new Timber piano starts Simulated, other instruments from their defaults', () {
    final layer = LayerDoc(id: 'l', name: 'Piano', color: 0, patternId: 'p')..setInstrument('org.caw.timber');
    expect(layer.instrument!.params, {'sim': 1.0});
    layer.instrument!.params['sim'] = 0;  // the user picks Classic: kept while the instrument stays
    layer.setInstrument('org.caw.timber');
    expect(layer.instrument!.params['sim'], 0);
    layer.setInstrument('org.caw.synth.flagship');
    expect(layer.instrument!.params, isEmpty);
    layer.setInstrument('org.caw.timber');
    expect(layer.instrument!.params['sim'], 1);
    // The map is a copy: one track's change never reaches the next new piano.
    layer.instrument!.params['sim'] = 0;
    expect(LayerDoc.newInstrumentValues['org.caw.timber'], {'sim': 1.0});
  });
}
