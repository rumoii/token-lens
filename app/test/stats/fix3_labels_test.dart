import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/sessions_page.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';

import 'fix1_regressions_test.dart' as f1;
import 'fix2_scope_test.dart' as f2;
import 'sessions_page_test.dart' as s;

void main() {
  for (final scenario in [
    (query: 'period=all&project=C%3A%2Fdemo', label: '筛选后', tokens: 42),
    (query: 'period=all&model=model-a', label: '筛选后', tokens: 200),
    (query: 'period=today', label: '今天', tokens: 200),
    (query: 'period=all&tool=&project=&model=', label: '全部', tokens: 200),
  ]) {
    testWidgets('详情用量标题反映口径：${scenario.query}', (tester) async {
      final fake = f1.FilteredSessionGateway();
      await s.mountSessions(tester, fake, query: scenario.query, reduced: true);
      await tester.tap(find.byKey(const Key('session-row-codex:s1')));
      await tester.pumpAndSettle();

      final detail = find.byType(SessionDetail);
      final values = tester
          .widgetList<TokenText>(
            find.descendant(of: detail, matching: find.byType(TokenText)),
          )
          .take(2)
          .map((widget) => widget.value)
          .toList();
      expect(values, [scenario.tokens, 200]);
      expect(
        find.descendant(of: detail, matching: find.text(scenario.label)),
        findsOneWidget,
      );
      if (scenario.label == '筛选后') {
        expect(
          find.descendant(of: detail, matching: find.text('全部')),
          findsNothing,
        );
      }
      expect(
        find.descendant(of: detail, matching: find.text('整个会话累计')),
        findsOneWidget,
      );
      final params = Uri.splitQueryString(scenario.query);
      expect(
        fake.detailFilter!.project,
        params['project']?.isNotEmpty == true ? params['project'] : null,
      );
      expect(
        fake.detailFilter!.model,
        params['model']?.isNotEmpty == true ? params['model'] : null,
      );
      expect(
        fake.detailFilter!.from,
        scenario.label == '今天' ? '2026-11-09' : null,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final scenario in [
    (query: 'period=all&project=C%3A%2Fdemo', label: '筛选后'),
    (query: 'period=all&tool=codex', label: '筛选后'),
    (query: 'period=all&model=model-a', label: '筛选后'),
    (query: 'period=today', label: '今天'),
  ]) {
    testWidgets('窄屏用量和请求都标明口径：${scenario.query}', (tester) async {
      await s.mountSessions(
        tester,
        f2.FilterScopeGateway(),
        query: scenario.query,
        width: 720,
        reduced: true,
      );
      final row = find.byKey(const Key('session-row-codex:cross-project'));
      expect(
        find.descendant(of: row, matching: find.text('${scenario.label} ')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text('${scenario.label} 1 次请求'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('累计 110 · 2 次请求')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TokenText>(
              find.descendant(of: row, matching: find.byType(TokenText)),
            )
            .value,
        10,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
