import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/runtime_errors.dart';

void main() {
  test('FIX2 完整首行传到 Rust，避免截断主目录后无法脱敏', () async {
    final errors = RuntimeErrors();
    final messages = <String>[];
    errors.sink = (_, message, _) async => messages.add(message);
    final home = r'C:\Users\' + 'PrivateUsername' * 20;
    final firstLine = '${'x' * 180}$home\\trace';
    errors.report(
      StateError('$firstLine\nPRIVATE_SECOND_LINE'),
      StackTrace.empty,
    );
    await Future<void>.delayed(Duration.zero);
    expect(messages.single, 'Bad state: $firstLine');
    expect(messages.single, isNot(contains('PRIVATE_SECOND_LINE')));
  });
  testWidgets('FIX1 启动和退出日志等待有界，写入失败不传播', (tester) async {
    final pending = Completer<void>();
    var complete = false;
    final work = writeRuntimeEvent(() => pending.future)
        .then((_) => complete = true);
    await tester.pump(const Duration(milliseconds: 301));
    expect(complete, isTrue);
    await work;
    pending.complete();
    await writeRuntimeEvent(() async => throw StateError('log unavailable'));
  });
  test('FIX1 只发送首行和有限的堆栈帧，长度由 Rust 脱敏后限制', () async {
    final errors = RuntimeErrors();
    final records = <(String, String)>[];
    errors.sink = (_, message, stack) async {
      records.add((message, stack));
    };
    errors.report(
      StateError('prompt:\nPRIVATE_TEXT'),
      StackTrace.fromString(
        'PRIVATE_STACK\n${List.generate(25, (i) => '#$i  frame (file:///app.dart:12:3)').join('\n')}',
      ),
    );
    errors.report(StateError('字' * 300), StackTrace.empty);
    await Future<void>.delayed(Duration.zero);
    expect(records.first.$1, isNot(contains('PRIVATE_TEXT')));
    expect(records.first.$2, isNot(contains('PRIVATE_STACK')));
    expect(records.first.$2.split('\n'), hasLength(20));
    expect(records.last.$1, 'Bad state: ${'字' * 300}');
  });
  test('启动期间的错误排队，消息不包含 FormatException 的 source', () async {
    final errors = RuntimeErrors();
    errors.report(
      const FormatException('Unexpected character', 'PRIVATE_SOURCE'),
      StackTrace.fromString('#0 frame (app.dart:12:3)'),
    );
    final written = <String>[];
    errors.sink = (type, message, stack) async {
      written.add('$type $message $stack');
    };
    await Future<void>.delayed(Duration.zero);
    expect(written.single, contains('FormatException Unexpected character'));
    expect(written.single, contains('#0 frame (app.dart:12:3)'));
    expect(written.single, isNot(contains('PRIVATE_SOURCE')));
  });
  test('日志接口失败不会递归或变成未捕获错误', () async {
    final errors = RuntimeErrors();
    var writes = 0;
    errors.sink = (_, _, _) async {
      writes++;
      throw StateError('disk unavailable');
    };
    errors.report(StateError('business failure'), StackTrace.current);
    await Future<void>.delayed(Duration.zero);
    expect(writes, 1);
  });
}
