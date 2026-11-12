// Tests ParamWatch (beta plan B4.5): a knob step rebuilds the parts that show that value and skips the rest, a part
// opened later or drawn by a lazy builder still follows its values, and any other change rebuilds everything.
import 'package:caw/model/device_target.dart';
import 'package:caw/ui/devices/kit/param_watch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';

void main() {
  testWidgets('a step rebuilds what shows the value, and only that', (tester) async {
    final s = stateWith('org.caw.compressor');
    addTearDown(s.dispose);
    final t = targetOf(s, 'org.caw.compressor');
    var page = 0, knob = 0, lazy = 0;
    double? shown;
    await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr, child: ParamWatch(target: t, page: true,
      builder: (context) {
        page++;
        t.value('ratio');
        return Column(children: [
          // A control: its own watch, its own value.
          ParamWatch(target: t, builder: (_) {
            knob++;
            return Text('${t.value('threshold')}');
          }),
          // Drawn in a LayoutBuilder (outside any watch's rebuild): the page takes the read.
          SizedBox(width: 10, height: 10, child: LayoutBuilder(builder: (_, _) {
            lazy++;
            shown = t.value('knee');
            return const SizedBox();
          })),
        ]);
      })));
    expect((page, knob, lazy), (1, 1, 1));
    t.setLive('threshold', -20);
    await tester.pump();
    expect((page, knob), (1, 2), reason: 'the threshold is the knob\'s alone');
    t.setLive('ratio', 3);
    await tester.pump();
    expect(page, 2, reason: 'the page shows the ratio');
    t.setLive('knee', 4);
    await tester.pump();
    expect(page, 3, reason: 'the lazy builder\'s read counts for the page');
    expect(shown, 4);
    // Anything but a plain step (a reset, an undo) rebuilds every watch.
    final before = (page, knob);
    s.layerValueTick('a').value++;
    await tester.pump();
    expect(page, before.$1 + 1);
    expect(DeviceTarget.moving, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5)); // the live edits' timers
  });
}
