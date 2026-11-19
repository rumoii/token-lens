import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop controls are constructed only in Lens primitives', () {
    const allowed = <String, String>{
      'lib/stats/widgets/primitives.dart': 'Shared control implementations.',
      'lib/stats/widgets/primitives_controls.dart':
          'LensInput wraps the editable text field here.',
    };
    final constructors = RegExp(
      r'\b(?:ChoiceChip|OutlinedButton|Switch|SwitchListTile|Checkbox|'
      r'CheckboxListTile|CheckboxMenuButton|TextField|PopupMenuButton|'
      r'showMenu|MenuAnchor|IconButton)(?:\.(?:adaptive|icon|filled|filledTonal|outlined))?'
      r'(?:<[^>]+>)?\s*\(',
    );
    final violations = <String>[];
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.startsWith('lib/src/')) continue;
      if (allowed.containsKey(path)) continue;
      final source = file.readAsStringSync();
      for (final match in constructors.allMatches(source)) {
        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        final constructor = match[0]!.replaceAll(RegExp(r'\s+'), '');
        violations.add('$path:$line: $constructor');
      }
    }
    expect(violations..sort(), isEmpty);
  });
}
