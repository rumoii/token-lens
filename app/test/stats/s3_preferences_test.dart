import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/preferences.dart';

void main() {
  test('hiddenTools defaults empty and preserves unrecognized IDs', () {
    expect(UiPreferences.decode('{}').hiddenTools, isEmpty);
    final preferences = UiPreferences.decode(
      '{"hiddenTools":["claude","future-tool",42,"claude"]}',
    );
    expect(preferences.hiddenTools, ['claude', 'future-tool']);
    expect(UiPreferences.decode(preferences.encode()).hiddenTools, [
      'claude',
      'future-tool',
    ]);
    expect(preferences.copyWith(language: 'en').hiddenTools, [
      'claude',
      'future-tool',
    ]);
  });
  test('hidden tools persist through the preferences store', () async {
    final directory = await Directory.systemTemp.createTemp(
      'token-lens-s3-prefs-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = PreferencesStore(directory);
    expect((await store.read()).hiddenTools, isEmpty);
    expect(
      await store.write(
        const UiPreferences(hiddenTools: ['codex', 'future-tool']),
      ),
      isTrue,
    );
    expect((await PreferencesStore(directory).read()).hiddenTools, [
      'codex',
      'future-tool',
    ]);
  });
}
