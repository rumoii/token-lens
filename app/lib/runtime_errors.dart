import 'dart:async';

import 'package:flutter/services.dart';

typedef RuntimeErrorSink = Future<void> Function(
  String type,
  String message,
  String stack,
);

Future<void> writeRuntimeEvent(Future<void> Function() action) async {
  try {
    await action().timeout(const Duration(milliseconds: 300));
  } catch (_) {
    // Startup and exit remain available when logging fails or times out.
  }
}

class RuntimeErrors {
  RuntimeErrorSink? _sink;
  final _pending = <(String, String, String)>[];
  set sink(RuntimeErrorSink value) {
    _sink = value;
    for (final record in _pending) {
      unawaited(_write(record));
    }
    _pending.clear();
  }

  void report(Object error, StackTrace stack) {
    // FormatException.toString includes its source; PlatformException includes details.
    final message = switch (error) {
      FormatException() => error.message,
      PlatformException() => '${error.code}: ${error.message ?? ''}',
      _ => error.toString(),
    };
    // Rust redacts home paths and sensitive fields before applying the length cap.
    final firstLine = message.split(RegExp(r'[\r\n]')).first;
    final frame = RegExp(r'^#\d+\s+.+ \(.+:\d+:\d+\)$');
    final frames = stack
        .toString()
        .split('\n')
        .map((line) => line.trim())
        .where(frame.hasMatch)
        .take(20)
        .join('\n');
    final record = (error.runtimeType.toString(), firstLine, frames);
    if (_sink == null) {
      if (_pending.length == 32) _pending.removeAt(0);
      _pending.add(record);
    } else {
      unawaited(_write(record));
    }
  }

  Future<void> _write((String, String, String) record) async {
    try {
      await _sink?.call(record.$1, record.$2, record.$3);
    } catch (_) {
      /* Never recurse through the error handler. */
    }
  }
}
