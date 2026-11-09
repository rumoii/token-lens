import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/src/rust/frb_generated.dart';
import 'package:token_lens_app/stats_gateway.dart';

void main() {
  test(
    'native gateway ingests a synthetic home and formats exact amounts',
    () async {
      final root = await Directory.systemTemp.createTemp('token-lens-d31-ffi-');
      await RustLib.init();
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
      expect((await gateway.pricing()).models.single.model, 'claude-opus-5-5');
      expect((await client.sync_()).unchanged, 1);
      expect(
        (await gateway.summary(const StatsFilter())).totals.costMicros,
        1054,
      );
    },
  );
}
