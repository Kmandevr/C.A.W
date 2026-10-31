// Regression tests for text-field key routing alongside the app's Vim/action shortcuts.
import 'package:caw/actions/actions.dart';
import 'package:caw/actions/keys.dart';
import 'package:caw/ui/key_router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('text editing key routing', () {
    bool defer(Area area, VimMode mode, String key, {bool ctrl = false}) =>
        shouldDeferTextEditingKey(
          editingText: true,
          commandLineOpen: false,
          area: area,
          mode: mode,
          chord: KeyChord(key, ctrl: ctrl),
        );

    test('Backspace, Delete and cursor/navigation keys reach EditableText in code Vim normal mode', () {
      for (final key in ['Backspace', 'Delete', 'Left', 'Right', 'Up', 'Down', 'Home', 'End', 'Enter', 'Tab']) {
        expect(defer(Area.code, VimMode.normal, key), isTrue, reason: key);
      }
    });

    test('ordinary code-editor letters still reach Vim normal mode', () {
      expect(defer(Area.code, VimMode.normal, 'I'), isFalse);
      expect(defer(Area.code, VimMode.normal, 'W'), isFalse);
    });

    test('insert mode and non-code text fields receive ordinary typing', () {
      expect(defer(Area.code, VimMode.insert, 'A'), isTrue);
      expect(defer(Area.arranger, VimMode.normal, 'A'), isTrue);
    });

    test('standard text editing shortcuts reach EditableText in every area', () {
      for (final key in ['Z', 'Y', 'A', 'C', 'V', 'X']) {
        expect(defer(Area.code, VimMode.normal, key, ctrl: true), isTrue, reason: key);
      }
    });

    test('Esc and the app command line remain owned by Vim', () {
      expect(defer(Area.code, VimMode.normal, 'Esc'), isFalse);
      expect(
        shouldDeferTextEditingKey(
          editingText: true,
          commandLineOpen: true,
          area: Area.code,
          mode: VimMode.insert,
          chord: KeyChord('Backspace'),
        ),
        isFalse,
      );
    });

    test('unfocused text fields do not affect action routing', () {
      expect(
        shouldDeferTextEditingKey(
          editingText: false,
          commandLineOpen: false,
          area: Area.arranger,
          mode: VimMode.normal,
          chord: KeyChord('Backspace'),
        ),
        isFalse,
      );
    });
  });
}
