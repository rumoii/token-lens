import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/smooth_wheel.dart';

Future<SmoothWheelController> mount(
  WidgetTester tester, {
  bool disableAnimations = false,
}) async {
  final controller = SmoothWheelController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(
          body: ListView(
            controller: controller,
            physics: const ClampingScrollPhysics(),
            children: const [SizedBox(height: 3000)],
          ),
        ),
      ),
    ),
  );
  return controller;
}

Future<void> wheel(WidgetTester tester, double delta) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  pointer.hover(tester.getCenter(find.byType(ListView)));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, delta)));
}

void main() {
  testWidgets('wheel animates through the first frame to the target', (
    tester,
  ) async {
    final controller = await mount(tester);
    await wheel(tester, 120);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(120));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(120, .01));
  });

  testWidgets('wheel accumulates deltas during the animation', (tester) async {
    final controller = await mount(tester);
    await wheel(tester, 120);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 45));
    expect(controller.offset, lessThan(120));
    await wheel(tester, 90);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(210, .01));
  });

  testWidgets('wheel clamps its target without restarting at the end', (
    tester,
  ) async {
    final controller = await mount(tester);
    final end = controller.position.maxScrollExtent;
    controller.jumpTo(end - 100);
    await wheel(tester, 200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(controller.offset, lessThan(end));
    expect(controller.offset, greaterThanOrEqualTo(0));
    await wheel(tester, 200);
    await tester.pump(const Duration(milliseconds: 120));
    expect(controller.offset, closeTo(end, .01));
    expect(controller.offset, lessThanOrEqualTo(end));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(end, .01));
  });

  testWidgets('reduced motion scrolls immediately', (tester) async {
    final controller = await mount(tester, disableAnimations: true);
    await wheel(tester, 120);
    expect(controller.offset, 120);
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('wheel starts from current pixels after a drag interruption', (
    tester,
  ) async {
    final controller = await mount(tester);
    await wheel(tester, 400);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 45));
    expect(controller.offset, lessThan(400));
    final drag = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await drag.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 50));
    final current = controller.offset;
    await wheel(tester, 100);
    await drag.up();
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(current + 100, .01));
  });

  testWidgets('wheel starts from current pixels after jumpTo', (tester) async {
    final controller = await mount(tester);
    await wheel(tester, 400);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 45));
    expect(controller.offset, lessThan(400));
    controller.jumpTo(50);
    await wheel(tester, 100);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(150, .01));
  });

  testWidgets('zero delta cancels the pending wheel target', (tester) async {
    final controller = await mount(tester);
    await wheel(tester, 400);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 45));
    final current = controller.offset;
    controller.position.pointerScroll(0);
    await wheel(tester, 100);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(current + 100, .01));
  });
}
