import 'package:flutter/material.dart';

import '../stats_controller.dart';
import 'theme/palette.dart';

class StatsSettingsPage extends StatelessWidget {
  const StatsSettingsPage({
    super.key,
    required this.controller,
    this.query = '',
    this.openLink,
  });
  final StatsController controller;
  final String query;
  final Future<bool> Function(Uri)? openLink;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('价格与设置', style: p.serif(30)),
        const SizedBox(height: 18),
        const Text('这一页还在迁移'),
        if (query.isNotEmpty) ...[
          const SizedBox(height: 16),
          SelectableText(
            query,
            key: const Key('detail-query'),
            style: p.text(13, p.secondary),
          ),
        ],
      ],
    );
  }
}
