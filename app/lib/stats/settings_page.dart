import 'package:flutter/material.dart';

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
  });
  final StatsController controller;
  final String query;
  final Future<bool> Function(Uri)? openLink;

  @override
  State<StatsSettingsPage> createState() => _StatsSettingsPageState();
}

class _StatsSettingsPageState extends State<StatsSettingsPage> {
  late final pricing = LensResource<StatsPricing>(changed);
  late final usage = LensResource<StatsBreakdown>(changed);
  late final health = LensResource<StatsHealth>(changed);
  bool aboutOpen = false;
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
