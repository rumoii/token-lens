import 'package:flutter/material.dart';

import 'stats/stats_page.dart';
import 'stats_controller.dart';

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    this.statsController,
    this.statsInitializationError,
    required this.news,
    this.openLink,
  });

  final StatsController? statsController;
  final String? statsInitializationError;
  final Widget news;
  final Future<bool> Function(Uri)? openLink;

  @override
  Widget build(BuildContext context) => statsController != null
      ? StatsPage(controller: statsController!, news: news, openLink: openLink)
      : Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                if (statsInitializationError != null)
                  MaterialBanner(
                    content: Text(statsInitializationError!),
                    leading: const Icon(Icons.info_outline),
                    actions: const [SizedBox.shrink()],
                  ),
                Expanded(child: news),
              ],
            ),
          ),
        );
}
