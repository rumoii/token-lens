import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/tool_order.dart';

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
  test('tool-colors: 8 个槽位及其他', () {
    final map = assignToolColors(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i']);
    expect(map['a'], 1);
    expect(map['h'], 8);
    expect(map['i'], 0);
  });
  test(
    'tool-colors: 与用量无关',
    () => expect(
      assignToolColors(
        toolOrder([
          row('dsh', '2026-10-17T00:00:00Z'),
          row('codex', '2026-10-18T00:00:00Z'),
        ]),
      )['dsh'],
      1,
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
