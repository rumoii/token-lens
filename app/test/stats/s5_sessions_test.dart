import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/sessions_page.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'fake_gateway.dart';
import 'sessions_page_test.dart' show SessionsGateway, mountSessions;

class SearchGateway extends SessionsGateway
    implements StatsSessionQueryGateway {
  final searches = <StatsSessionQuery>[];

  @override
  Future<StatsSessions> querySessions(
    StatsFilter filter,
    StatsSessionQuery query,
  ) {
    searches.add(query);
    if (query.q == 'missing') {
      return Future.value(
        const StatsSessions(items: [], snapshot: demoSnapshot),
      );
    }
    return sessions(filter, limit: query.limit!, cursor: query.cursor);
  }
}

void main() {
  testWidgets(
    'S5 search debounces and survives navigation; clear resets first page',
    (tester) async {
      final fake = SearchGateway();
      await mountSessions(
        tester,
        fake,
        query: 'q=original&sort=recent&dir=asc',
      );
      final search = find.byType(TextField);
      final state = tester.state(find.byType(StatsPage)) as dynamic;
      Map<String, String> query() =>
          Uri.splitQueryString(state.query as String);
      expect(tester.widget<TextField>(search).controller!.text, 'original');
      expect(fake.searches.last.q, 'original');
      await tester.enterText(search, 'missing');
      await tester.pump(const Duration(milliseconds: 249));
      expect(fake.searches.last.q, 'original');
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(fake.searches.last.q, 'missing');
      expect(query(), containsPair('q', 'missing'));
      expect(find.text('没有找到和“missing”匹配的会话'), findsOneWidget);
      state.navigate('home');
      await tester.pumpAndSettle();
      state.navigate('sessions');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, 'missing');
      expect(query(), containsPair('dir', 'asc'));
      await tester.tap(find.byTooltip('清除'));
      await tester.pumpAndSettle();
      expect(query().containsKey('q'), isFalse);
      expect(fake.searches.last.cursor, isNull);
      expect(find.byKey(const Key('session-row-codex:s1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('S5 sorting dropdown and headers share URL order', (
    tester,
  ) async {
    final fake = SearchGateway();
    await mountSessions(tester, fake);
    Map<String, String> query() => Uri.splitQueryString(
      tester.widget<StatsSessionsPage>(find.byType(StatsSessionsPage)).query,
    );
    await tester.tap(find.byKey(const Key('sessions-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始时间'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('sessions-sort')),
        matching: find.text('开始时间'),
      ),
      findsOneWidget,
    );
    expect(query(), containsPair('sort', 'started'));
    expect(query(), containsPair('dir', 'desc'));
    await tester.tap(find.byKey(const Key('sessions-header-started')));
    await tester.pumpAndSettle();
    expect(fake.searches.last.dir, 'asc');
    expect(find.byTooltip('升序'), findsOneWidget);
    expect(query(), containsPair('dir', 'asc'));
    expect(tester.takeException(), isNull);
  });
}
