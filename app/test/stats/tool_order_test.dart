import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/tool_order.dart';
import 'package:token_lens_app/stats/theme/palette.dart';

void main() {
  SourceOrderRow row(String source, String? first, [int records = 1]) =>
      (source: source, firstObservedAt: first, records: records);
  test(
    'tool-colors: 首次出现，无记录不参与',
    () => expect(
      toolOrder([
        row('codex', '2026-10-18T00:00:00Z'),
        row('dsh', '2026-10-17T01:00:00Z'),
        row('claude', '2026-10-17T02:00:00Z'),
        row('zed', null, 0),
      ]),
      ['dsh', 'claude', 'codex'],
    ),
  );
  test(
    'tool-colors: 同时或缺失按 id',
    () => expect(
      toolOrder([
        row('qwen', null),
        row('pi', '2026-10-17T00:00:00Z'),
        row('aider', '2026-10-17T00:00:00Z'),
      ]),
      ['aider', 'pi', 'qwen'],
    ),
  );
  test('tool-colors: 墨色 5 档，第 5 档复用', () {
    final map = assignToolColors([
      ('a', 9),
      ('b', 8),
      ('c', 7),
      ('d', 6),
      ('e', 5),
      ('f', 4),
    ], const LensPalette(false));
    expect(map['a'], const Color(0xff3b3936));
    expect(map['e'], const Color(0xffcbc8c0));
    expect(map['f'], const Color(0xffcbc8c0));
  });
  test(
    'tool-colors: 品牌色与用量无关',
    () => expect(
      assignToolColors([
        ('dsh', 1),
        ('codex', 2),
      ], const LensPalette(false))['dsh'],
      const Color(0xff4d68e8),
    ),
  );
  test(
    'tool-colors: 未知最后',
    () => expect(sortByToolOrder(['new', 'codex', 'dsh'], ['dsh', 'codex']), [
      'dsh',
      'codex',
      'new',
    ]),
  );
}
