// The code editors' font size, tab width, line numbers and wrap from Settings › Code editor, read where editors build.

/// Set by Settings whenever it changes (as Haptics.strength and Motion are), so the editors need no settings object.
class CodePrefs {
  /// The .caw editor's font size; the C++ editor's is this scaled to its denser default (12.5 at 15).
  static double fontSize = 15;
  static double get cppFontSize => fontSize * 12.5 / 15;

  /// The C++ editor's indent (Tab, a new line's indent), its gutter's line numbers and soft wrap.
  static int tabWidth = 4;
  static bool lineNumbers = true;
  static bool wrap = false;
}
