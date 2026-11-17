import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/src/rust/frb_generated.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'detail_page_test.dart' as d;

class LedgerDetailGateway extends d.DetailGateway {
  LedgerDetailGateway(this.native);
  final RustStatsGateway native;
  StatsSummary? pageSummary;
  StatsFilter? pageFilter;
  StatsRequests? pageRequests;
  final requestReady = Completer<StatsRequests>();
  Future<StatsSummary>? summaryReady;
  @override
  Future<StatsSummary> summary(StatsFilter filter) {
    pageFilter = filter;
    return summaryReady = native
        .summary(filter)
        .then((value) => pageSummary = value);
  }

  @override
  Future<StatsRequests> requestList(
    StatsFilter filter,
    StatsRequestQuery query,
  ) async {
    final result = pageRequests = await native.requestList(filter, query);
    requestReady.complete(result);
    return result;
  }
}

void main() {
  setUpAll(() => RustLib.init());
  for (final bucket in ['2026-11', '2026-11-09', '2026-11-09T08:00:00']) {
    testWidgets('FIX1 URL 桶 $bucket 真实请求列表与页面总计事件部分对账', (tester) async {
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'reqlog-fix1-scope-',
        );
        final logs = await Directory('${root.path}/home/.codex/sessions')
            .create(recursive: true);
        await File('${logs.path}/rollout-synthetic.jsonl').writeAsString(
          [
            for (final (hour, input) in [(8, 100), (15, 200)])
              jsonEncode({
                'type': 'token_usage_record',
                'timestamp': DateTime(
                  2026,
                  11,
                  9,
                  hour,
                  10,
                ).toUtc().toIso8601String(),
                'payload': {
                  'session_id': 'synthetic-session',
                  'thread_id': 'root',
                  'response_id': 'resp_synthetic_scope_$hour',
                  'usage': {'input_tokens': input, 'output_tokens': 10},
                },
              }),
          ].join('\n'),
        );
        final native = RustStatsGateway(
          await StatsClient.newInstance(
            dataDir: '${root.path}/data',
            logsHome: '${root.path}/home',
          ),
        );
        addTearDown(() async {
          await native.shutdown();
          final temp = await Directory.systemTemp.resolveSymbolicLinks();
          final target = await root.resolveSymbolicLinks();
          if (!target.startsWith('$temp${Platform.pathSeparator}')) {
            throw StateError('Synthetic directory escaped TEMP');
          }
          await root.delete(recursive: true);
        });
        expect((await native.sync()).inserted, 2);
        final gateway = LedgerDetailGateway(native);
        await d.mountDetail(
          tester,
          gateway,
          query: 'period=month&view=detail&dim=request&bucket=$bucket',
          reduced: true,
        );
        await gateway.requestReady.future.timeout(const Duration(seconds: 10));
        await gateway.summaryReady;
        await tester.pumpAndSettle();
        final page = gateway.pageRequests!;
        expect(page.total, 2);
        expect(page.items.length, 2);
        final totals = gateway.pageSummary!.totals;
        expect(
          page.items.fold<int>(0, (s, r) => s + (r.inputTokens ?? 0)),
          totals.inputTokens,
        );
        expect(
          page.items.fold<int>(0, (s, r) => s + (r.outputTokens ?? 0)),
          totals.outputTokens,
        );
        expect(
          page.items.fold<int>(0, (s, r) => s + (r.cacheReadTokens ?? 0)),
          totals.cacheReadTokens ?? 0,
        );
        expect(
          page.items.fold<int>(0, (s, r) => s + (r.cacheWriteTokens ?? 0)),
          totals.cacheWriteTokens ?? 0,
        );
        final events = (await native.breakdown(
          'source',
          gateway.pageFilter!,
        )).groups.single;
        expect(page.total, events.requestCount);
        expect(
          page.items.fold<int>(
            0,
            (s, r) =>
                s +
                (r.inputTokens ?? 0) +
                (r.outputTokens ?? 0) +
                (r.cacheReadTokens ?? 0) +
                (r.cacheWriteTokens ?? 0),
          ),
          events.eventGrossTokens,
        );
        for (final item in page.items) {
          expect(
            find.byKey(ValueKey('request-row-${item.id}')),
            findsOneWidget,
          );
        }
      });
    });
  }
}
