import 'dart:async';

import 'package:flutter/material.dart';

import '../stats_controller.dart';
import '../stats_gateway.dart';
import 'theme/palette.dart';
import 'widgets/onboarding_content.dart';
import 'widgets/resource.dart';

class StatsOnboardingGate extends StatelessWidget {
  const StatsOnboardingGate({
    super.key,
    required this.controller,
    required this.child,
  });
  final StatsController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      if (controller.preferences.onboarded) return child;
      return FutureBuilder<bool>(
        key: ObjectKey(controller),
        future: controller.onboardingRequired(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return ColoredBox(
              key: const Key('onboarding-loading'),
              color: LensPalette.of(context)['surface-0'],
              child: const SizedBox.expand(),
            );
          }
          return snapshot.data == true
              ? _OnboardingPage(controller: controller)
              : child;
        },
      );
    },
  );
}

class _OnboardingPage extends StatefulWidget {
  const _OnboardingPage({required this.controller});
  final StatsController controller;
  @override
  State<_OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<_OnboardingPage> {
  late final discovery = LensResource<StatsDiscovery>(changed);
  late final completed = LensResource<StatsSummary>(changed);
  OnboardingStep step = OnboardingStep.discover;
  bool fresh = false;
  late bool localOnly = !c.preferences.newsEnabled;
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
    unawaited(
      c.startOnboardingSync(localOnly: localOnly).then((_) => observe()),
    );
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
    localOnly: localOnly,
    onLocalOnlyChanged: (value) => setState(() => localOnly = value),
    onRescan: () {
      fresh = true;
      unawaited(discovery.reload());
    },
    onEnter: () =>
        unawaited(c.setPreferences(c.preferences.copyWith(onboarded: true))),
  );
}
