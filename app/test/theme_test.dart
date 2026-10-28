// Tests the theme file round trip, its error handling and that Neon colours follow the active theme.
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => Neon.active = calmNeon);

  test('every starter theme survives a file round trip', () {
    for (final t in starterThemes) {
      final back = CawTheme.parse(t.toFile());
      expect(back.name, t.name);
      expect(back.glow, t.glow);
      for (final s in CawTheme.slots.keys) {
        expect(back[s].toARGB32(), t[s].toARGB32(), reason: '${t.name} $s');
      }
      expect(back.toFile(), t.toFile());
    }
  });

  test('the file is readable key: #RRGGBB text with a theme header', () {
    final f = calmNeon.toFile();
    expect(f, startsWith('---\nkind: theme\nname: Calm neon\n---\n'));
    expect(f, contains('bg: #07070B\n'));
    expect(f, contains('glow: on\n'));
  });

  test('missing colours fall back to Calm neon; unknown keys are ignored', () {
    final t = CawTheme.parse('---\nkind: theme\nname: Mine\n---\nbg: #112233\nfuture_key: 7\nglow: off\n');
    expect(t.name, 'Mine');
    expect(t.glow, isFalse);
    expect(t['bg'].toARGB32(), 0xFF112233);
    expect(t['pink'].toARGB32(), calmNeon['pink'].toARGB32());
  });

  test('a file that is not a theme, or has a bad colour, is refused', () {
    expect(() => CawTheme.parse('---\nkind: effect\n---\nin'), throwsFormatException);
    expect(() => CawTheme.parse('kind: theme\nbg: #12'), throwsFormatException);
  });

  test('Neon colours, even const ones, read the active theme', () {
    const c = Neon.bg;
    expect(c.toARGB32(), 0xFF07070B);
    Neon.active = starterThemes.firstWhere((t) => t.name == 'Night');
    expect(c.toARGB32(), Neon.active['bg'].toARGB32());
    expect(Neon.layer(1).toARGB32(), Neon.active['layer2'].toARGB32());
    expect(Neon.glow(Neon.green), isEmpty); // Night has glow off
    expect((Paint()..color = Neon.pink).color.toARGB32(), Neon.active['pink'].toARGB32());
  });
}
