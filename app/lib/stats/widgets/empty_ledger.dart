import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../stats_controller.dart';
import '../../stats_gateway.dart';
import '../logic/tools.dart';
import '../theme/palette.dart';
import 'primitives.dart';

class EmptyLedgerCard extends StatelessWidget {
  const EmptyLedgerCard({super.key, required this.controller, this.onTools});

  final StatsController controller;
  final VoidCallback? onTools;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context), s = context.strings;
    return LensCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: p['clay-wash'],
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.sync, color: p['clay-ink'], size: 24),
                ),
                const SizedBox(height: 12),
                Text(
                  s.noUsageYet,
                  style: p.serif(22, weight: FontWeight.w500),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  s.tokenLensReadsAiCodingToolLogs,
                  style: p.text(13, p.secondary),
                  textAlign: TextAlign.center,
                ),
                FutureBuilder<StatsDiscovery>(
                  future: controller.discoverEmptyLedgerTools(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done ||
                        !snapshot.hasData) {
                      return const SizedBox.shrink();
                    }
                    final tools = snapshot.data!.sources;
                    return Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: Column(
                        spacing: 8,
                        children: [
                          Text(
                            tools.isEmpty
                                ? s.noSupportedToolsDiscovered
                                : s.discoveredLogTools(tools.length),
                            textAlign: TextAlign.center,
                            style: p.text(12.5, p.secondary, FontWeight.w500),
                          ),
                          if (tools.isNotEmpty)
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final tool in tools.take(6))
                                  _pill(p, [
                                    ToolTile(tool.source, size: 16),
                                    Text(
                                      toolOf(tool.source).name,
                                      style: p.text(12),
                                    ),
                                    Text(
                                      s.discoveredLogFiles(tool.files),
                                      style: p.text(11.5, p.muted),
                                    ),
                                  ]),
                                if (tools.length > 6)
                                  _pill(p, [
                                    Text(
                                      s.moreDiscoveredTools(tools.length - 6),
                                      style: p.text(12, p.muted),
                                    ),
                                  ]),
                              ],
                            ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 18),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    LensButton(
                      label: s.syncNow,
                      variant: 'primary',
                      onPressed: () => unawaited(controller.sync()),
                    ),
                    LensButton(label: s.viewToolSources, onPressed: onTools),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: 6,
                  children: [
                    Icon(Icons.lock_outline, size: 14, color: p.muted),
                    Flexible(
                      child: Text(
                        s.readsLogsOnThisComputerAndLeaves,
                        textAlign: TextAlign.center,
                        style: p.text(12, p.muted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pill(LensPalette p, List<Widget> contents) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: p['fill-hover'],
      borderRadius: BorderRadius.circular(99),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, spacing: 5, children: contents),
  );
}
