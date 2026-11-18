import 'dart:async';

import 'package:flutter/material.dart';

import '../stats/theme/palette.dart';
import '../stats/widgets/primitives.dart';
import 'update_check.dart';
import 'update_controller.dart';

String updateDate(DateTime date, DateTime now) {
  final local = date.toLocal();
  return '${local.year == now.year ? '' : '${local.year}年'}${local.month}月${local.day}日';
}

String updateAttemptTime(int ms, DateTime now) {
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
      ? '今天'
      : days == 1
      ? '昨天'
      : updateDate(date, now);
  return '$day ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
}

class SettingsUpdate extends StatelessWidget {
  const SettingsUpdate({super.key, required this.controller, this.openLink});
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
          : updateAttemptTime(prefs.updateLastAttemptMs!, now);
      final suffix = prefs.autoCheckUpdates ? '明天会再试，也可以现在重试。' : '可以现在重试。';
      final published = prefs.updateResult?.publishedAt;
      final status = controller.checking
          ? ('text-faint', '正在检查…', '你现在用的是 $current')
          : switch (kind) {
              UpdateKind.available => (
                'clay',
                '$latest 可以更新了',
                '${published == null ? '' : '${updateDate(published, now)}发布 · '}你现在用的是 $current',
              ),
              UpdateKind.latest => ('ok', '$current 已是最新', '$time 检查过'),
              UpdateKind.none => (
                'ok',
                '$current 是目前唯一的版本',
                'GitHub 上还没有正式发布的版本 · $time 检查过',
              ),
              UpdateKind.offline => (
                'warn',
                '没检查成功',
                '连不上 GitHub · $time。$suffix',
              ),
              UpdateKind.limited => (
                'warn',
                '没检查成功',
                'GitHub 暂时拒绝了请求（同一网络下请求太多）· $time。过一会儿再试。',
              ),
              UpdateKind.invalid => (
                'warn',
                '没检查成功',
                'GitHub 返回的内容读不懂 · $time。$suffix',
              ),
              null => (
                'text-faint',
                '你现在用的是 $current',
                prefs.autoCheckUpdates ? '还没检查过' : '还没检查过 · 自动检查已关',
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
              Text('更新', style: p.text(15, null, FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                '有新版本时提示你，去 GitHub 的发布页下载。程序不会自己下载或安装。',
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
                      label: '打开下载页',
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
                            ? '正在检查…'
                            : [
                                UpdateKind.offline,
                                UpdateKind.limited,
                                UpdateKind.invalid,
                              ].contains(kind)
                            ? '重试'
                            : '检查更新',
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
                        child: const Text('这个版本不再提示'),
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
                    label: '每天自动检查一次',
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
                              child: Text('每天自动检查一次', style: p.text(13)),
                            ),
                          ),
                        ),
                        Text(
                          '只向 api.github.com 询问本项目最新的正式版本，不带账号、凭据或用量数据。关掉后只在点“检查更新”时联网。',
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
                  message: '点开看怎么更新',
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
                                '有新版本 $version',
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
                    tooltip: '这个版本不再提示',
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
