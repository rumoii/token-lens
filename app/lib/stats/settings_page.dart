import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../stats_controller.dart';
import '../stats_gateway.dart';
import 'theme/palette.dart';
import 'widgets/primitives.dart';
import 'widgets/resource.dart';
import 'widgets/settings_display.dart';
import 'widgets/settings_prices.dart';

class StatsSettingsPage extends StatefulWidget {
  const StatsSettingsPage({
    super.key,
    required this.controller,
    this.query = '',
    this.openLink,
    this.downloadsDirectory,
  });
  final StatsController controller;
  final String query;
  final Future<bool> Function(Uri)? openLink;
  final Future<Directory?> Function()? downloadsDirectory;

  @override
  State<StatsSettingsPage> createState() => _StatsSettingsPageState();
}

class _StatsSettingsPageState extends State<StatsSettingsPage> {
  late final pricing = LensResource<StatsPricing>(changed);
  late final usage = LensResource<StatsBreakdown>(changed);
  late final health = LensResource<StatsHealth>(changed);
  bool aboutOpen = false;
  bool exporting = false;
  String? exportPath, exportError;

  Future<void> exportDiagnostics() async {
    if (exporting) return;
    setState(() {
      exporting = true;
      exportPath = null;
      exportError = null;
    });
    final gateway = widget.controller.gateway;
    try {
      Directory? downloads;
      try {
        downloads =
            await (widget.downloadsDirectory ?? getDownloadsDirectory)();
      } catch (_) {
        /* Fall back to the app data directory. */
      }
      final directory =
          downloads?.path ??
          '${(await gateway.health()).dataDir}${Platform.pathSeparator}exports';
      final path = await gateway.exportDiagnostics(directory);
      if (mounted) setState(() => exportPath = path);
    } catch (error, stack) {
      if (mounted) setState(() => exportError = '导出失败：$error');
      try {
        await gateway.logError(
          error.runtimeType.toString(),
          error.toString(),
          stack.toString(),
        );
      } catch (_) {
        /* Logging cannot fail the export UI. */
      }
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  Future<void> openExportFolder() async {
    final path = exportPath;
    if (path == null) return;
    try {
      final opened = await widget.openLink?.call(
        Uri.directory(File(path).parent.path),
      );
      if (opened != true) throw StateError('无法打开所在文件夹');
    } catch (error, stack) {
      if (mounted) setState(() => exportError = '打开文件夹失败：$error');
      try {
        await widget.controller.gateway.logError(
          error.runtimeType.toString(),
          error.toString(),
          stack.toString(),
        );
      } catch (_) {
        /* Best effort. */
      }
    }
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void read() {
    final c = widget.controller,
        identity = (widget.controller.gateway, widget.controller.ledgerVersion);
    pricing.read(identity, c.gateway.pricing);
    usage.read(
      identity,
      () => c.gateway.breakdown('source_model', const StatsFilter()),
    );
    health.read(c.gateway, c.gateway.health);
  }

  void controllerChanged() {
    read();
    changed();
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(controllerChanged);
    read();
  }

  @override
  void didUpdateWidget(StatsSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.removeListener(controllerChanged);
      widget.controller.addListener(controllerChanged);
      read();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(controllerChanged);
    pricing.dispose();
    usage.dispose();
    health.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 768;
    Widget gap() => SizedBox(height: narrow ? 12 : 16);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '价格与设置',
          style: p
              .serif(narrow ? 24 : 28, weight: FontWeight.w500)
              .copyWith(height: 1.25, letterSpacing: -(narrow ? 24 : 28) * .01),
        ),
        const SizedBox(height: 4),
        Text('数字怎么显示，金额怎么算。', style: p.text(14, p.secondary)),
        gap(),
        LensCard(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('诊断', style: p.text(15, null, FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  '遇到统计不对、同步报错或者应用卡住时，导出一份诊断日志发给维护者。',
                  style: p.text(12.5, p.muted),
                ),
                const SizedBox(height: 14),
                OutlinedButton(
                  onPressed: exporting ? null : exportDiagnostics,
                  child: Text(exporting ? '正在导出…' : '导出诊断日志'),
                ),
                const SizedBox(height: 8),
                Text(
                  '包含：应用和系统版本、最近 10 次同步的结果和全部异常、各工具找到的日志文件数和路径、最近 7 天的运行日志。\n不包含：账本、任何对话内容。用户目录会显示成 ~。',
                  style: p.text(12, p.muted),
                ),
                if (exportPath != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: SelectableText(
                      '已保存到：$exportPath',
                      style: p.text(13),
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: openExportFolder,
                    child: const Text('打开所在文件夹'),
                  ),
                ],
                if (exportError != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: SelectableText(exportError!, style: p.text(13)),
                  ),
                ],
              ],
            ),
          ),
        ),
        gap(),
        SettingsDisplay(controller: widget.controller),
        gap(),
        LensCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('价格', style: p.text(15, null, FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      '金额是按各模型的公开价算出来的，用来比较和感知，不是你的账单。用套餐的话，实际花费通常更低。',
                      style: p.text(12.5, p.muted),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
                child: ResourceBlock(
                  resource: usage,
                  rows: 1,
                  builder: (_) => ResourceBlock(
                    resource: pricing,
                    rows: 5,
                    builder: (data) => SettingsPrices(
                      pricing: data!,
                      usage: usage.data,
                      preferences: widget.controller.preferences,
                      openLink: widget.openLink,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        gap(),
        LensCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                expanded: aboutOpen,
                button: true,
                child: InkWell(
                  onTap: () => setState(() => aboutOpen = !aboutOpen),
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        AnimatedRotation(
                          turns: aboutOpen ? .25 : 0,
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 140),
                          child: Icon(
                            Icons.chevron_right,
                            size: 14,
                            color: p.secondary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '关于这台电脑上的 Token Lens',
                            style: p.text(13.5, p.secondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (aboutOpen)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                  child: ResourceBlock(
                    resource: health,
                    rows: 2,
                    builder: (data) => Table(
                      columnWidths: const {
                        0: IntrinsicColumnWidth(),
                        1: FlexColumnWidth(),
                      },
                      children: [
                        for (final item in [
                          ('版本', data?.version ?? '—'),
                          ('数据目录', data?.dataDir ?? '—'),
                          ('账本路径', data?.ledgerPath ?? '—'),
                          ('schema 版本', data?.schemaVersion.toString() ?? '—'),
                          (
                            '价格表版本',
                            '${pricing.data?.priceVersion ?? '—'} · 内置',
                          ),
                        ])
                          TableRow(
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(
                                  right: 14,
                                  bottom: 4,
                                ),
                                child: Text(
                                  item.$1,
                                  style: p.text(13, p.muted),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: SelectableText(
                                  item.$2,
                                  style: p
                                      .text(13)
                                      .copyWith(
                                        fontFamily: LensPalette.monoFonts.first,
                                        fontFamilyFallback: LensPalette
                                            .monoFonts
                                            .skip(1)
                                            .toList(),
                                      ),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
