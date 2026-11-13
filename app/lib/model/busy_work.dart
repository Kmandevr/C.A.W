// Counts long work in flight (song exports, music video renders) so an automatic update never installs under it.
import 'package:flutter/foundation.dart';

class BusyWork {
  BusyWork._();

  /// How many renders or exports run now.
  static final ValueNotifier<int> running = ValueNotifier(0);

  static bool get any => running.value > 0;

  /// Counts [work] while it runs.
  static Future<T> during<T>(Future<T> Function() work) async {
    running.value++;
    try {
      return await work();
    } finally {
      running.value--;
    }
  }
}
