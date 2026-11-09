import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/logic/period.dart';
import 'package:token_lens_app/stats/logic/format.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('token-lens-d34a-prefs-');
  });
  tearDown(() async {
    final root = await Directory.systemTemp.resolveSymbolicLinks();
    final target = await directory.resolveSymbolicLinks();
    if (!target.startsWith('$root${Platform.pathSeparator}')) {
      throw StateError('Preference test directory escaped TEMP');
    }
    await directory.delete(recursive: true);
  });
  test('损坏、不合法内容和缺失回到默认', () async {
    final store = PreferencesStore(directory);
    expect((await store.read()).appearance, 'system');
    for (final value in [
      '{',
      'null',
      '[]',
      '42',
      '{"appearance":2}',
      '{"period":{"period":"custom","from":"2026-02-30","to":"2026-03-01"}}',
      '{"period":{"period":"custom","from":false}}',
    ]) {
      await File('${directory.path}/ui-preferences.json').writeAsString(value);
      final preferences = await store.read();
      expect(preferences.appearance, 'system');
      expect(preferences.currency, 'USD');
      expect(preferences.period.period, 'week');
    }
  });
  test('并发写串行、落盘为完整 JSON、最后写入获胜', () async {
    final store = PreferencesStore(directory);
    final other = PreferencesStore(directory);
    final results = await Future.wait([
      for (var i = 0; i < 30; i++)
        (i.isEven ? store : other).write(
          UiPreferences(
            appearance: i.isEven ? 'dark' : 'light',
            period: StatsPeriod(
              'custom',
              '2026-10-01',
              '2026-10-${(i + 1).toString().padLeft(2, '0')}',
            ),
          ),
        ),
    ]);
    expect(results.every((ok) => ok), isTrue);
    await store.flush();
    final read = await other.read();
    expect(read.appearance, 'light');
    expect(read.period.to, '2026-10-30');
    expect(
      directory.listSync().whereType<File>().map(
        (f) => f.uri.pathSegments.last,
      ),
      ['ui-preferences.json'],
    );
  });
  test('写入失败不阻断偏好读取', () async {
    final blocker = File('${directory.path}/blocked');
    await blocker.writeAsString('fixture');
    final store = PreferencesStore(Directory(blocker.path));
    expect(await store.write(const UiPreferences(appearance: 'dark')), isFalse);
    expect((await store.read()).appearance, 'system');
  });
  test('period.test.js 记住的自定义周期可重载', () async {
    final store = PreferencesStore(directory);
    expect((await store.read()).period.period, 'week');
    await store.write(
      const UiPreferences(
        period: StatsPeriod('custom', '2026-10-01', '2026-10-05'),
      ),
    );
    final period = (await store.read()).period;
    expect(period.from, '2026-10-01');
    expect(period.to, '2026-10-05');
    expect(StatsPeriod.parse(period.query).query, period.query);
  });
  test('token-format.test.js 独立单位与模式、应用默认中文', () async {
    final store = PreferencesStore(directory);
    expect((await store.read()).unitSystem, 'chinese');
    expect((await store.read()).tokenMode, 'compact');
    expect(normalizeTokenMode('invalid'), 'compact');
    expect(normalizeTokenUnit('invalid'), 'english');
    await store.write(
      const UiPreferences(tokenMode: 'full', unitSystem: 'chinese'),
    );
    expect((await store.read()).tokenMode, 'full');
    expect((await store.read()).unitSystem, 'chinese');
  });
  test('currency.test.ts 读写币种归一化、过滤已移除值', () async {
    final store = PreferencesStore(directory);
    await File('${directory.path}/ui-preferences.json')
        .writeAsString('{"currency":" cny "}');
    expect((await store.read()).currency, 'CNY');
    await File('${directory.path}/ui-preferences.json')
        .writeAsString('{"currency":"EUR"}');
    expect((await store.read()).currency, 'USD');
    await store.write(const UiPreferences(currency: 'CNY'));
    expect((await store.read()).currency, 'CNY');
  });
}
