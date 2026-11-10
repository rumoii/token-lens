import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats_gateway.dart';

import 'fake_gateway.dart';

class ClientSpy implements StatsClient {
  final calls = <Invocation>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation);
    if (invocation.memberName == #sessions) {
      return Future.value(
        const StatsSessions(items: [], snapshot: demoSnapshot),
      );
    }
    if (invocation.memberName == #sessionDetail) {
      return Future<StatsSessionDetail?>.value(null);
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  test('gateway 保留 filter、limit、cursor 和当前偏移', () async {
    final spy = ClientSpy();
    final gateway = RustStatsGateway(spy);
    const filter = StatsFilter(source: 'codex', project: 'C:/demo');
    await gateway.sessions(filter, limit: 50, cursor: 'opaque/+==');
    final args = spy.calls.single.namedArguments;
    expect(args[#filter], filter);
    expect(args[#limit], 50);
    expect(args[#cursor], 'opaque/+==');
    expect(args[#offsetMinutes], DateTime.now().timeZoneOffset.inMinutes);
  });
  test('gateway 会话详情 source/sessionId/granularity 原样传递，不存在保留 null', () async {
    final spy = ClientSpy();
    final gateway = RustStatsGateway(spy);
    expect(await gateway.sessionDetail('claude', 'demo:1/2', 'hour'), isNull);
    expect(spy.calls.single.memberName, #sessionDetail);
    expect(spy.calls.single.namedArguments, {
      #source: 'claude',
      #sessionId: 'demo:1/2',
      #granularity: 'hour',
      #offsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
    });
  });
}
