// Tests the bundled pattern templates: each is a pattern, and each matches its file in examples/ word for word.
import 'dart:io';

import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/pattern_templates.dart';
import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the bundled pattern templates are patterns and match examples/', () {
    expect(patternTemplates.map((t) => t.file), ['acid-line.caw', 'chords.caw']);
    for (final t in patternTemplates) {
      expect(isPatternSource(t.source), isTrue, reason: t.file);
      expect(PatternDoc.parse(t.source).doc, isNotNull, reason: t.file);
      expect(t.source, File('../examples/${t.file}').readAsStringSync(), reason: t.file);
    }
  });
}
