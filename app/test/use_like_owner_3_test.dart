// Part 3 of 4 of the owner-use suite's big group (use_like_owner_test.dart): every control of this part's built-in devices touched with a finger and a mouse at phone size, and each move reaching the engine (devices assigned by use_like_owner/harness.dart's parts).
import 'use_like_owner/harness.dart';

Future<void> main() async {
  everyControlPart(await ownerSuite(), 3);
}
