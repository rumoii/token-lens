import 'dart:async';

import 'package:flutter/material.dart';

import '../stats_controller.dart';
import '../stats_gateway.dart';
import 'theme/palette.dart';
import 'widgets/onboarding_content.dart';
import 'widgets/resource.dart';

class StatsOnboardingGate extends StatefulWidget {
  const StatsOnboardingGate({
    super.key,
    required this.controller,
    required this.child,
  });
  final StatsController controller;
  final Widget child;

  @override
  State<StatsOnboardingGate> createState() => _StatsOnboardingGateState();
}

enum _Gate { loading, onboard, app }

class _StatsOnboardingGateState extends State<StatsOnboardingGate> {
  late LensResource<StatsSummary> initial;
  _Gate gate = _Gate.loading;

  @override
  void initState() {
    super.initState();
    initialize();
  }

  void initialize() {
    gate = widget.controller.preferences.onboarded ? _Gate.app : _Gate.loading;
    initial = LensResource(() {
      if (!mounted) return;
      setState(() {
        if (gate != _Gate.loading) return;
        if (initial.fresh) {
          gate = initial.data!.totals.recordCount == 0
              ? _Gate.onboard
              : _Gate.app;
        } else if (initial.error != null) {
          gate = _Gate.app;
        }
      });
    });
    if (gate == _Gate.loading) {
      initial.read(
        'initial',
        () => widget.controller.gateway.summary(const StatsFilter()),
      );
    }
  }

  @override
  void didUpdateWidget(StatsOnboardingGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      initial.dispose();
      initialize();
    }
  }

  @override
  void dispose() {
    initial.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      if (widget.controller.preferences.onboarded || gate == _Gate.app) {
        return widget.child;
      }
      if (gate == _Gate.loading) {
        return ColoredBox(
          key: const Key('onboarding-loading'),
          color: LensPalette.of(context)['surface-0'],
          child: const SizedBox.expand(),
        );
      }
      return _OnboardingPage(
        key: ObjectKey(widget.controller),
        controller: widget.controller,
      );
    },
  );
}

class _OnboardingPage extends StatefulWidget {
  const _OnboardingPage({super.key, required this.controller});
  final StatsController controller;
  @override
  State<_OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<_OnboardingPage> {
  late final discovery = LensResource<StatsDiscovery>(changed);
  late final completed = LensResource<StatsSummary>(changed);
  OnboardingStep step = OnboardingStep.discover;
  bool fresh = false;
  StatsController get c => widget.controller;

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    c.addListener(observe);
    discovery.read('discovery', () => c.gateway.discovery(fresh: fresh));
  }

  void observe() {
    if (!mounted) return;
    if (step == OnboardingStep.counting) {
      if (c.phase == StatsSyncPhase.error) {
        step = OnboardingStep.discover;
      } else if (c.phase == StatsSyncPhase.success && !c.loading) {
        step = OnboardingStep.done;
        completed.read(
          'completed',
          () => c.gateway.summary(const StatsFilter()),
        );
      }
    }
    changed();
  }

  void start() {
    setState(() => step = OnboardingStep.counting);
    final work = c.syncErrorKind == StatsSyncErrorKind.status
        ? c.retryStatus()
        : c.sync();
    // The controller owns startup synchronization and conflict observation.
    unawaited(work.then((_) => observe()));
  }

  @override
  void dispose() {
    c.removeListener(observe);
    discovery.dispose();
    completed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OnboardingContent(
    controller: c,
    step: step,
    discovery: discovery,
    completed: completed,
    onStart: start,
    onRescan: () {
      fresh = true;
      unawaited(discovery.reload());
    },
    onEnter: () =>
        unawaited(c.setPreferences(c.preferences.copyWith(onboarded: true))),
  );
}
