// Poller tests: meters are read while playing, settle after stopping, then nothing runs until woken.
import 'package:caw/model/poller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('reads while moving, settles, then stops and goes idle', (tester) async {
    var playing = true, reads = 0, idle = 0;
    final p = Poller(
      poll: () {
        reads++;
        return playing;
      },
      onIdle: () => idle++,
    );
    p.wake();
    await tester.pump(const Duration(seconds: 1));
    expect(reads, inInclusiveRange(29, 31)); // about 30 a second while playing
    playing = false;
    await tester.pump(const Duration(seconds: 2));
    expect(p.running, isFalse); // settled: no timer, no work
    final settled = reads;
    await tester.pump(const Duration(seconds: 10));
    expect(reads, settled);
    expect(idle, 0);
    await tester.pump(const Duration(seconds: 30));
    expect(idle, 1); // the audio device may close now
    p.wake();
    expect(p.running, isTrue);
    p.dispose();
  });

  testWidgets('nothing runs in the background', (tester) async {
    var reads = 0;
    final p = Poller(poll: () {
      reads++;
      return true;
    });
    p.wake();
    p.setVisible(false);
    await tester.pump(const Duration(seconds: 5));
    expect(reads, 0);
    expect(p.running, isFalse);
    p.setVisible(true);
    await tester.pump(const Duration(milliseconds: 100));
    expect(reads, greaterThan(0));
    p.dispose();
  });
}
