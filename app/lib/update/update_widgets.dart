import '../l10n/app_strings.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../stats/theme/palette.dart';
import '../stats/widgets/primitives.dart';
import 'update_check.dart';
import 'update_controller.dart';

String updateDate(
  DateTime date,
  DateTime now, [
  AppStrings strings = chineseStrings,
]) {
  final local = date.toLocal();
  return local.year == now.year
      ? strings.calendarDay(local.month, local.day)
      : strings.calendarDayWithYear(local.year, local.month, local.day);
}

String updateAttemptTime(
  int ms,
  DateTime now, [
  AppStrings strings = chineseStrings,
]) {
  DateTime date;
  try {
    date = DateTime.fromMillisecondsSinceEpoch(ms);
  } catch (_) {
    return '—';
  }
  final days = DateTime.utc(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime.utc(date.year, date.month, date.day)).inDays;
  final day = days == 0
      ? strings.today
      : days == 1
      ? strings.yesterday
      : updateDate(date, now, strings);
  return '$day ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
}

class SettingsUpdate extends StatelessWidget {
  const SettingsUpdate({
    super.key,
    required this.controller,
    this.openLink,
    this.networkHeader,
  });
  final Widget? networkHeader;
  final UpdateController controller;
  final Future<bool> Function(Uri)? openLink;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final p = LensPalette.of(context), prefs = controller.readPreferences();
      final current = controller.currentVersion ?? '—';
      final now = controller.clock();
      var kind = controller.currentVersion == null
          ? null
          : prefs.updateResult?.kind;
      final latest = prefs.updateResult?.version;
      if (kind == UpdateKind.available &&
          latest != null &&
          UpdateVersion.parse(latest)!
                  .compareTo(UpdateVersion.parse(current)!) <=
              0) {
        kind = UpdateKind.latest;
      }
      if (kind != UpdateKind.available && prefs.updateLastAttemptMs == null) {
        kind = null;
      }
      final time = prefs.updateLastAttemptMs == null
          ? '—'
          : updateAttemptTime(prefs.updateLastAttemptMs!, now, context.strings);
      final suffix = prefs.autoCheckUpdates
          ? context.strings.theAppWillTryAgainTomorrowYou
          : context.strings.youCanRetryNow;
      final published = prefs.updateResult?.publishedAt;
      final status = controller.checking
          ? (
              'text-faint',
              context.strings.checking,
              context.strings.currentVersion(current),
            )
          : switch (kind) {
              UpdateKind.available => (
                'clay',
                context.strings.updateAvailable(latest),
                context.strings.updateAvailableDetails(
                  published == null
                      ? ''
                      : context.strings.releaseDatePrefix(
                          updateDate(published, now, context.strings),
                        ),
                  current,
                ),
              ),
              UpdateKind.latest => (
                'ok',
                context.strings.upToDate(current),
                context.strings.checkedAt(time),
              ),
              UpdateKind.none => (
                'ok',
                context.strings.onlyVersionSoFar(current),
                context.strings.noReleaseCheckResult(time),
              ),
              UpdateKind.offline => (
                'warn',
                context.strings.updateCheckFailed,
                context.strings.unreachableUpdateCheck(time, suffix),
              ),
              UpdateKind.limited => (
                'warn',
                context.strings.updateCheckFailed,
                context.strings.rateLimitedUpdateCheck(time),
              ),
              UpdateKind.invalid => (
                'warn',
                context.strings.updateCheckFailed,
                context.strings.invalidUpdateCheckResponse(time, suffix),
              ),
              null => (
                'text-faint',
                context.strings.currentVersion(current),
                prefs.autoCheckUpdates
                    ? context.strings.neverChecked
                    : context.strings.neverCheckedAutomaticChecksOff,
              ),
            };
      final available = kind == UpdateKind.available && !controller.checking;
      return LensCard(
        key: const Key('update-card'),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (networkHeader case final header?) ...[
                header,
                Divider(
                  height: 1,
                  thickness: LensPalette.hairline(context),
                  color: p['line-soft'],
                ),
                const SizedBox(height: 12),
              ],
              Text(
                context.strings.updates,
                style: p.text(15, null, FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                context.strings.getANoticeWhenANewVersion,
                style: p.text(12.5, p.muted),
              ),
              const SizedBox(height: 14),
              Semantics(
                liveRegion: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: p[status.$1],
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            status.$2,
                            style: p.text(15, null, FontWeight.w500),
                          ),
                          const SizedBox(height: 1),
                          Text(status.$3, style: p.text(12.5, p.muted)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 14,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (available)
                    LensButton(
                      label: context.strings.openDownloadPage,
                      variant: 'primary',
                      size: 'settings',
                      icon: Icons.open_in_new,
                      onPressed: () async {
                        try {
                          await openLink?.call(updateDownloadPage(latest!));
                        } catch (_) {
                          /* The system browser owns opening the link. */
                        }
                      },
                    ),
                  LensFocusOutline(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: const StadiumBorder(),
                      ),
                      onPressed:
                          controller.checking ||
                              controller.currentVersion == null
                          ? null
                          : () => unawaited(controller.check()),
                      child: Text(
                        controller.checking
                            ? context.strings.checking
                            : [
                                UpdateKind.offline,
                                UpdateKind.limited,
                                UpdateKind.invalid,
                              ].contains(kind)
                            ? context.strings.retry
                            : context.strings.checkForUpdates,
                      ),
                    ),
                  ),
                  if (available && prefs.updateIgnoredVersion != latest)
                    LensFocusOutline(
                      child: TextButton(
                        onPressed: () => unawaited(controller.ignoreVersion()),
                        style: TextButton.styleFrom(
                          foregroundColor: p['clay-ink'],
                          textStyle: p
                              .text(12.5)
                              .copyWith(decoration: TextDecoration.underline),
                        ),
                        child: Text(context.strings.dismissThisVersion),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(
                height: 1,
                thickness: LensPalette.hairline(context),
                color: p['line-soft'],
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    label: context.strings.checkAutomaticallyOnceADay,
                    child: Transform.translate(
                      // Align the painted square while keeping its compact tap target.
                      offset: const Offset(-(40 - Checkbox.width) / 2, 0),
                      child: Checkbox(
                        value: prefs.autoCheckUpdates,
                        activeColor: p['clay'],
                        visualDensity: VisualDensity.compact,
                        onChanged: (value) =>
                            unawaited(controller.setAutomatic(value ?? false)),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LensFocusOutline(
                          child: InkWell(
                            onTap: () => unawaited(
                              controller.setAutomatic(!prefs.autoCheckUpdates),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Text(
                                context.strings.checkAutomaticallyOnceADay,
                                style: p.text(13),
                              ),
                            ),
                          ),
                        ),
                        Text(
                          context.strings.asksApiGithubComForTheLatest,
                          style: p.text(12, p.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

class UpdateHint extends StatelessWidget {
  const UpdateHint({super.key, required this.controller, required this.onOpen});
  final UpdateController controller;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (!controller.showHint) return const SizedBox.shrink();
      final p = LensPalette.of(context),
          version = controller.readPreferences().updateResult!.version!;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Material(
          key: const Key('update-hint'),
          color: p['clay-wash'],
          borderRadius: BorderRadius.circular(8),
          child: Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: context.strings.viewUpdateDetails,
                  child: LensFocusOutline(
                    child: InkWell(
                      key: const Key('update-hint-open'),
                      onTap: onOpen,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
                        child: Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: p['clay'],
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                context.strings.newVersion(version),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: p.text(12.5, p['clay-ink']),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(4),
                child: LensFocusOutline(
                  radius: 6,
                  inset: true,
                  child: IconButton(
                    key: const Key('update-hint-dismiss'),
                    tooltip: context.strings.dismissThisVersion,
                    onPressed: () => unawaited(controller.ignoreVersion()),
                    padding: EdgeInsets.zero,
                    style: IconButton.styleFrom(
                      fixedSize: const Size.square(28),
                      minimumSize: const Size.square(28),
                      maximumSize: const Size.square(28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    icon: Icon(Icons.close, size: 14, color: p['clay-ink']),
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      );
    },
  );
}
