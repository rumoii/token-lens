import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../stats_controller.dart';
import '../logic/tools.dart';
import '../theme/palette.dart';
import 'primitives.dart';

class StatsSyncTitle extends StatelessWidget {
  const StatsSyncTitle({
    super.key,
    required this.controller,
    required this.title,
  });

  final StatsController controller;
  final Text title;

  @override
  Widget build(BuildContext context) {
    final c = controller, s = context.strings, p = LensPalette.of(context);
    final active = c.phase == StatsSyncPhase.running && !c.fullSyncRunning;
    if (!active && !c.recentlySynced) return title;
    final source = c.progress?.source;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: title),
        const SizedBox(width: 9),
        Flexible(
          child: Container(
            key: const Key('stats-sync-capsule'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: p[active ? 'clay-wash' : 'surface-0'],
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              active
                  ? source == null
                        ? s.syncing2
                        : s.progressSyncing(toolOf(source).name)
                  : s.progressSynced,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: p.text(11, p[active ? 'clay-ink' : 'ok'], FontWeight.w500),
            ),
          ),
        ),
      ],
    );
  }
}

class StatsSyncBanner extends StatelessWidget {
  const StatsSyncBanner({super.key, required this.controller, this.onSources});

  final StatsController controller;
  final VoidCallback? onSources;

  @override
  Widget build(BuildContext context) {
    final c = controller, p = LensPalette.of(context), s = context.strings;
    final receipt = c.syncReceipt;
    final progress = c.progress;
    if (c.fullSyncRunning) {
      final title = c.rereading ? s.progressReread : s.progressFirst;
      final source = progress?.source;
      final reading = progress?.stage == 'reading' && source != null;
      return LensCard(
        key: const Key('stats-sync-progress'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Text(
              reading
                  ? s.progressReading(
                      title,
                      toolOf(source).name,
                      progress!.index,
                      progress.total,
                      progress.filesRead,
                    )
                  : s.progressDiscovering(title),
              style: p.text(13, p['clay-ink'], FontWeight.w500),
            ),
            LinearProgressIndicator(
              minHeight: 3,
              value: reading && progress!.total > 0
                  ? (progress.index - 1) / progress.total
                  : MediaQuery.disableAnimationsOf(context)
                  ? .06
                  : null,
              color: p['clay'],
              backgroundColor: p['clay-wash'],
              borderRadius: BorderRadius.circular(5),
            ),
          ],
        ),
      );
    }
    if (receipt == null) return const SizedBox.shrink();
    final failed = receipt.reason != null;
    final color = p[failed ? 'danger' : 'warn'];
    return LensCard(
      key: const Key('stats-sync-receipt'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Icon(
            failed ? Icons.error_outline : Icons.warning_amber,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              failed
                  ? s.progressFailed(receipt.reason!)
                  : s.progressIssues(receipt.issues),
              style: p.text(13, color, FontWeight.w500),
            ),
          ),
          if (onSources != null)
            LensButton(
              label: s.viewDetails,
              size: 'xs',
              variant: 'ghost',
              onPressed: onSources,
            ),
          LensIconButton(
            tooltip: s.progressDismiss,
            icon: Icons.close,
            onPressed: () => c.dismissSyncReceipt(receipt.id),
          ),
        ],
      ),
    );
  }
}

class StatsHiddenNotice extends StatelessWidget {
  const StatsHiddenNotice({
    super.key,
    required this.controller,
    required this.onManage,
  });

  final StatsController controller;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context), s = context.strings;
    return Wrap(
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '${s.hiddenToolsNotice(controller.hiddenTools.length)} ·',
          style: p.text(12, p.muted),
        ),
        LensTextLink(label: s.hiddenToolsManage, onTap: onManage),
      ],
    );
  }
}
