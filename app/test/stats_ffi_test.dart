import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/src/rust/frb_generated.dart';
import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/src/rust/api/diagnostics.dart' as diagnostics;
import 'package:token_lens_app/runtime_errors.dart';
import 'package:token_lens_app/stats/logic/period.dart';

void main() {
  setUpAll(() => RustLib.init());
  test('E2 native diagnostics exports isolated data through the generated bridge', () async {
    final root = await Directory.systemTemp.createTemp('token-lens-e2-native-');
    final home = '${root.path}/home';
    final data = '$home/data';
    final logs = await Directory('$home/.claude/projects')
        .create(recursive: true);
    const marker = 'E2_FFI_PRIVATE_PROMPT_TOOL_748C';
    await File('${logs.path}/synthetic.jsonl').writeAsString(
      '''{"sessionId":"synthetic","timestamp":"2026-01-15T01:00:00Z","prompt":"$marker","message":{"id":"synthetic","model":"unknown","content":[{"type":"text","text":"$marker"},{"type":"tool_use","input":{"command":"$marker"}}],"usage":{"input_tokens":10}}}
''',
    );
    final codex = await Directory('$home/.codex/sessions')
        .create(recursive: true);
    Map<String, Object> usage(String thread, String time, int input) => {
      'type': 'token_usage_record',
      'timestamp': time,
      'payload': {
        'session_id': 'integration-codex',
        'thread_id': thread,
        'response_id': 'resp_0',
        'usage': {'input_tokens': input, 'output_tokens': 0},
      },
    };
    final copied = [
      usage('root', '2026-01-15T01:00:00Z', 100),
      usage('root', '2026-01-15T01:01:00Z', 200),
    ];
    await File('${codex.path}/rollout-a.jsonl')
        .writeAsString('${copied.map(jsonEncode).join('\n')}\n');
    await File('${codex.path}/rollout-b.jsonl').writeAsString(
      '${[...copied, usage('child', '2026-01-15T01:02:00Z', 300)].map(jsonEncode).join('\n')}\n',
    );
    await diagnostics.runtimeStart(dataDir: data, logsHome: home);
    final client = await StatsClient.newInstance(dataDir: data, logsHome: home);
    final gateway = RustStatsGateway(client);
    addTearDown(() async {
      await gateway.shutdown();
      final temp = await Directory.systemTemp.resolveSymbolicLinks();
      final target = await root.resolveSymbolicLinks();
      if (!target.startsWith('$temp${Platform.pathSeparator}')) {
        throw StateError('Synthetic directory escaped TEMP');
      }
      await root.delete(recursive: true);
    });
    final first = await gateway.sync(trigger: 'startup');
    expect(first.inserted, 4);
    expect(first.parsedFiles, 3);
    final cached = await gateway.sync(trigger: 'manual');
    expect(cached.skippedFiles, 3);
    expect(cached.attempted, 0);
    expect((await gateway.sources()).lastRun!.skippedFiles, 3);
    final reread = await gateway.sync(trigger: 'reread');
    expect(reread.parsedFiles, 3);
    expect(reread.skippedFiles, 0);
    expect(reread.unchanged, 4);
    expect(
      (await gateway.summary(const StatsFilter())).totals.grossTokens,
      610,
    );
    final codexSession = (await gateway.sessions(
      const StatsFilter(source: 'codex'),
    )).items.single;
    expect(codexSession.requestCount, 3);
    expect(codexSession.grossTokens, 600);
    expect(codexSession.eventGrossTokens, 600);
    StatsRequestQuery requestQuery({
      int offset = 0,
      bool summary = true,
      String? source,
      String? session,
    }) => StatsRequestQuery(
      source: source,
      sessionId: session,
      timedOnly: false,
      sort: 'time',
      descending: true,
      limit: 2,
      offset: offset,
      includeSummary: summary,
    );
    final firstRequests = await gateway.requestList(
      const StatsFilter(source: 'codex'),
      requestQuery(),
    );
    final moreRequests = await gateway.requestList(
      const StatsFilter(source: 'codex'),
      requestQuery(offset: 2, summary: false),
    );
    expect(firstRequests.total, 3);
    expect(firstRequests.slow!.ttftMs, isNull);
    expect(firstRequests.items.length, 2);
    expect(moreRequests.total, isNull);
    expect(moreRequests.slow, isNull);
    final allRequests = [...firstRequests.items, ...moreRequests.items];
    expect(allRequests.map((r) => r.id).toSet().length, 3);
    expect(
      allRequests.fold<int>(0, (sum, r) => sum + (r.inputTokens ?? 0)),
      600,
    );
    expect(
      allRequests.every(
        (r) =>
            r.ttftMs == null && r.speedTps == null && r.throughputTps == null,
      ),
      isTrue,
    );
    final lifetime = await gateway.requestList(
      const StatsFilter(from: '2020-01-01', to: '2020-01-02'),
      requestQuery(source: 'codex', session: 'integration-codex'),
    );
    expect(lifetime.total, 3);
    expect(lifetime.snapshot.filters.sessionId, 'integration-codex');
    final detail = (await gateway.sessionDetail(
      'codex',
      'integration-codex',
      'day',
      filter: const StatsFilter(from: '2026-01-14', to: '2026-01-16'),
    ))!;
    expect(detail.period!.requestCount, 3);
    expect(detail.period!.grossTokens, 600);
    expect(detail.session.requestCount, 3);
    await expectLater(
      gateway.sessionDetail('codex', 'integration-codex', 'invalid'),
      throwsA(anything),
    );
    final errors = RuntimeErrors();
    final logged = <Future<void>>[];
    errors.sink = (type, message, stack) {
      final work = diagnostics.writeRuntimeError(
        dataDir: data,
        logsHome: home,
        errorType: type,
        message: message,
        stack: stack,
      );
      logged.add(work);
      return work;
    };
    errors.report(
      const FormatException('Unexpected character', marker),
      StackTrace.fromString('#0 $home/app.dart:12'),
    );
    await Future.wait(logged);
    await expectLater(
      gateway.breakdown('invalid', const StatsFilter()),
      throwsA(anything),
    );
    await diagnostics.runtimeExit(dataDir: data, logsHome: home);
    final path = await gateway.exportDiagnostics('${root.path}/exports');
    final text = await File(path).readAsString();
    for (final section in ['[应用]', '[最近同步]', '[来源]', '[运行日志]']) {
      expect(text, contains(section));
    }
    for (final event in [
      'start version=',
      'exit',
      'trigger=startup',
      'trigger=reread',
      'files=3',
      'inserted=4',
      'unchanged=4',
      'session_detail_in_period',
      'FormatException',
      'ERROR ffi',
      'schema=7',
    ]) {
      expect(text, contains(event));
    }
    expect(text, isNot(contains(marker)));
    expect(text, isNot(contains('open schema=')));
    expect(text, isNot(contains(home)));
    expect(text, isNot(contains(home.replaceAll('/', Platform.pathSeparator))));
    expect(text, contains('~'));
    expect(
      File(path).uri.pathSegments.last,
      matches(RegExp(r'^token-lens-diagnostics-\d{8}-\d{6}\.txt$')),
    );
    final sample = Platform.environment['TOKEN_LENS_E2_SAMPLE'];
    if (sample != null) await File(path).copy(sample);
  });
  test(
    'native gateway ingests a synthetic home and formats exact amounts',
    () async {
      final root = await Directory.systemTemp.createTemp('token-lens-d31-ffi-');
      final logs = Directory('${root.path}/home/.claude/projects');
      await logs.create(recursive: true);
      await File('${logs.path}/synthetic.jsonl').writeAsString('''{"sessionId":"synthetic","timestamp":"2026-01-15T01:00:00Z","message":{"id":"synthetic","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":30,"cache_read_input_tokens":20,"cache_creation_input_tokens":10}}}
''');
      final client = await StatsClient.newInstance(
        dataDir: '${root.path}/data',
        logsHome: '${root.path}/home',
      );
      final gateway = RustStatsGateway(client);
      addTearDown(() async {
        await gateway.shutdown();
        final temp = await Directory.systemTemp.resolveSymbolicLinks();
        final target = await root.resolveSymbolicLinks();
        if (!target.startsWith('$temp${Platform.pathSeparator}')) {
          throw StateError('Synthetic test directory escaped TEMP');
        }
        await root.delete(recursive: true);
      });
      final first = await client.sync_();
      expect(first.inserted, 1);
      final view = await gateway.summary(const StatsFilter());
      expect(view.totals.grossTokens, 160);
      expect(view.totals.costMicros, 1054);
      expect(view.totals.costUsd, '0.001054');
      expect(
        (await gateway.breakdown(
          'source',
          const StatsFilter(),
        )).groups.single.key,
        'claude',
      );
      expect(
        (await gateway.breakdown(
          'model',
          const StatsFilter(),
        )).groups.single.costByKind!.inputMicros,
        400,
      );
      expect((await gateway.sources()).lastRun!.status, 'ok');
      expect(
        (await gateway.timeseries(
          'day',
          const StatsFilter(),
        )).points.single.grossTokens,
        160,
      );
      expect(
        (await gateway.matrix(
          'day',
          'source',
          const StatsFilter(),
        )).rows.single.key,
        'claude',
      );
      expect(
        (await gateway.sessions(const StatsFilter())).items.single.sessionId,
        'synthetic',
      );
      final session = (await gateway.sessions(const StatsFilter()))
          .items
          .single;
      expect(session.requestCount, 1);
      expect(session.eventGrossTokens, 160);
      expect(session.hasCumulative, isFalse);
      expect(session.cumulative.grossTokens, 160);
      expect(session.cumulative.costMicros, 1054);
      expect(session.cumulative.requestCount, 1);
      expect(session.cumulative.eventGrossTokens, 160);
      final observedDay = DateTime.parse('2026-01-15T01:00:00Z').toLocal();
      final from = dayKey(observedDay);
      final outsideDay = dayKey(
        DateTime(observedDay.year, observedDay.month, observedDay.day + 1),
      );
      final detail = (await gateway.sessionDetail(
        'claude',
        'synthetic',
        'day',
        filter: StatsFilter(from: from, to: from),
      ))!;
      expect(detail.period!.grossTokens, 160);
      expect(detail.period!.costMicros, 1054);
      expect(detail.period!.requestCount, 1);
      expect(detail.session.requestCount, 1);
      expect(detail.timeline.single.requestCount, 1);
      expect(detail.timeline.single.eventGrossTokens, 160);
      expect(detail.period!.eventGrossTokens, 160);
      expect(
        (await gateway.breakdown(
          'model',
          const StatsFilter(),
        )).groups.single.requestCount,
        1,
      );
      final outside = (await gateway.sessionDetail(
        'claude',
        'synthetic',
        'day',
        filter: StatsFilter(from: outsideDay, to: outsideDay),
      ))!;
      expect(outside.period!.grossTokens, 0);
      expect(outside.period!.requestCount, 0);
      expect(outside.session.grossTokens, 160);
      expect((await gateway.pricing()).models.single.model, 'claude-opus-5-5');
      final cached = await client.sync_();
      expect(cached.skippedFiles, 1);
      expect(cached.unchanged, 0);
      expect((await client.syncTriggered(trigger: 'reread')).unchanged, 1);
      expect(
        (await gateway.summary(const StatsFilter())).totals.costMicros,
        1054,
      );
    },
  );
}
