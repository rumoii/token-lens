import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/window_theme.dart';

const channel = MethodChannel('token_lens/window');

void windowTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<void> mount(WidgetTester tester, ThemeMode mode) => tester.pumpWidget(
  WindowTheme(
    themeMode: mode,
    child: MaterialApp(
      themeMode: mode,
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeAnimationDuration: Duration.zero,
      home: Builder(
        builder: (context) => Text(Theme.of(context).brightness.name),
      ),
    ),
  ),
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> calls;
  setUp(() {
    calls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    windowTest('$mode sends its bool on the first frame', (tester) async {
      List<MethodCall>? atFirstFrame;
      binding.addPostFrameCallback((_) => atFirstFrame = List.of(calls));
      await mount(tester, mode);
      expect(atFirstFrame?.map((c) => c.method), ['setDarkTitleBar']);
      expect(atFirstFrame?.single.arguments, mode == ThemeMode.dark);
      expect(calls.map((c) => c.method), ['setDarkTitleBar']);
      expect(calls.single.arguments, mode == ThemeMode.dark);
      expect(
        find.text(mode == ThemeMode.dark ? 'dark' : 'light'),
        findsOneWidget,
      );
    });
  }

  windowTest('system follows both platform brightness transitions', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await mount(tester, ThemeMode.system);
    expect(calls.map((c) => c.arguments), [false]);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    expect(calls.map((c) => c.arguments), [false, true]);
    expect(find.text('dark'), findsOneWidget);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pump();
    expect(calls.map((c) => c.arguments), [false, true, false]);
    expect(find.text('light'), findsOneWidget);
  });

  windowTest('appearance changes send only changed effective values', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await mount(tester, ThemeMode.light);
    await mount(tester, ThemeMode.dark);
    await mount(tester, ThemeMode.system);
    expect(calls.map((c) => c.arguments), [false, true, false]);
    await mount(tester, ThemeMode.light);
    await mount(tester, ThemeMode.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    expect(calls.map((c) => c.arguments), [false, true, false]);
    expect(find.text('light'), findsOneWidget);
  });

  windowTest('duplicates are suppressed while the native reply is pending', (
    tester,
  ) async {
    final reply = Completer<void>();
    addTearDown(() => reply.complete());
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return reply.future;
    });
    await mount(tester, ThemeMode.dark);
    await mount(tester, ThemeMode.dark);
    expect(calls.map((c) => c.arguments), [true]);
  });

  for (final missing in [true, false]) {
    windowTest(
      '${missing ? 'missing plugin' : 'platform error'} leaves UI usable',
      (tester) async {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          calls.add(call);
          if (missing) throw MissingPluginException();
          throw PlatformException(code: 'dwm-failed');
        });
        await mount(tester, ThemeMode.dark);
        await tester.pump();
        expect(find.text('dark'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await mount(tester, ThemeMode.light);
        await tester.pump();
        expect(find.text('light'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(calls.map((c) => c.arguments), [true, false]);
      },
    );
  }

  windowTest('non-Windows targets never call the window channel', (
    tester,
  ) async {
    for (final platform in TargetPlatform.values.where(
      (p) => p != TargetPlatform.windows,
    )) {
      debugDefaultTargetPlatformOverride = platform;
      await mount(tester, ThemeMode.dark);
      await mount(tester, ThemeMode.light);
    }
    expect(calls, isEmpty);
  });

  windowTest('unmount detaches the platform brightness observer', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await mount(tester, ThemeMode.system);
    expect(calls.map((c) => c.arguments), [false]);
    await tester.pumpWidget(const SizedBox());
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    expect(calls.map((c) => c.arguments), [false]);
  });
}
