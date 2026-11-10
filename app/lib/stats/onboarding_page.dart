import 'package:flutter/widgets.dart';

import '../stats_controller.dart';

class StatsOnboardingGate extends StatelessWidget {
  const StatsOnboardingGate({
    super.key,
    required this.controller,
    required this.child,
  });
  final StatsController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
