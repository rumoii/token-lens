import 'dart:async';

import 'package:flutter/widgets.dart';

const _wheelDuration = Duration(milliseconds: 180);
const _wheelCurve = Curves.easeOutCubic;

class SmoothWheelController extends ScrollController {
  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _SmoothWheelPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _SmoothWheelPosition extends ScrollPositionWithSingleContext {
  _SmoothWheelPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  ScrollActivity? _wheelActivity;
  double? _wheelTarget;

  @override
  void pointerScroll(double delta) {
    final notificationContext = context.notificationContext;
    final disableAnimations =
        (notificationContext == null
            ? null
            : MediaQuery.maybeDisableAnimationsOf(notificationContext)) ??
        WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .disableAnimations;
    if (delta == 0 || disableAnimations) {
      super.pointerScroll(delta);
      return;
    }

    // Only our still-current activity owns the accumulated wheel target.
    final origin = activity == _wheelActivity ? _wheelTarget ?? pixels : pixels;
    final target = (origin + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == origin) return;
    unawaited(animateTo(target, duration: _wheelDuration, curve: _wheelCurve));
    _wheelActivity = activity;
    _wheelTarget = target;
  }
}
