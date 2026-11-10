// Tests that native-component automation lanes stay on their effect when a track's chain is edited.
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a lane follows its effect through insert, move and remove, and goes with it', () {
    final s = AppState()
      ..project = (ProjectDoc(id: 'p', name: 't')..layers.add(LayerDoc(id: 'L', name: 'T', color: 0)));
    final layer = s.project.layers.single;
    s.addNativeEffect(layer, 'org.caw.distortion');
    s.addNativeEffect(layer, 'org.caw.chorus');
    final lane = ProjectAutomationLaneDoc(targetType: 'component', target: 'mix', layerId: 'L', component: 1);
    s.project.automation.add(lane);
    s.addNativeEffect(layer, 'org.caw.stereo.width', at: 0);
    expect(lane.component, 2, reason: 'an insert before it shifts it');
    s.moveNativeEffect(layer, 2, 0);
    expect(lane.component, 0);
    s.removeNativeEffect(layer, 1);
    expect(lane.component, 0, reason: 'removing another effect keeps it on the chorus');
    expect(layer.components[lane.component!].id, 'org.caw.chorus');
    s.removeNativeEffect(layer, 0);
    expect(s.project.automation, isEmpty, reason: 'removing the chorus removes its lane');
  });
}
