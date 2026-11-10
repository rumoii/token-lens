import 'dart:async';

import 'package:flutter/material.dart';

import '../../stats_controller.dart';
import '../logic/exchange_rate.dart';
import '../logic/format.dart';
import '../theme/palette.dart';
import 'primitives.dart';

/// Supplies a fake transport without changing the shared page constructor.
class SettingsExchangeScope extends InheritedWidget {
  const SettingsExchangeScope({
    super.key,
    required this.request,
    required super.child,
  });
  final ExchangeRateRequest request;
  static ExchangeRateRequest? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SettingsExchangeScope>()
      ?.request;
  @override
  bool updateShouldNotify(SettingsExchangeScope oldWidget) =>
      request != oldWidget.request;
}

class SettingsDisplay extends StatefulWidget {
  const SettingsDisplay({super.key, required this.controller});
  final StatsController controller;
  @override
  State<SettingsDisplay> createState() => _SettingsDisplayState();
}

class _SettingsDisplayState extends State<SettingsDisplay> {
  ExchangeRateOperation? _operation;
  String? _error;
  void _cancel() {
    final old = _operation;
    _operation = null;
    old?.cancel();
  }

  @override
  void didUpdateWidget(SettingsDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      _cancel();
      _error = null;
    }
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_operation != null) return;
    final c = widget.controller;
    final operation = ExchangeRateOperation(
      request: SettingsExchangeScope.of(context),
      clock: c.clock,
    );
    setState(() {
      _operation = operation;
      _error = null;
    });
    try {
      final result = await operation.fetch(reason: 'user-click');
      if (!mounted || _operation != operation) return;
      await c.setPreferences(
        c.preferences.copyWith(
          rates: result.rates,
          rateSource: 'fetched',
          ratesFetchedAt: result.fetchedAt,
        ),
      );
    } catch (failure) {
      if (mounted && _operation == operation) {
        setState(() => _error = '汇率更新失败：$failure');
      }
    } finally {
      if (mounted && _operation == operation) setState(() => _operation = null);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final p = LensPalette.of(context), c = widget.controller;
      final prefs = c.preferences;
      final narrow = MediaQuery.sizeOf(context).width < 768;
      Widget segment(
        String title,
        Map<String, String> options,
        String value,
        ValueChanged<String> changed,
      ) => LensSegmented(
        options: options,
        value: value,
        onChanged: changed,
        label: title,
      );
      Widget row(
        String title,
        String hint,
        List<Widget> controls, {
        String? note,
      }) => Container(
        decoration: BoxDecoration(
          border: title == '外观'
              ? null
              : Border(
                  top: BorderSide(
                    width: LensPalette.hairline(context),
                    color: p['line-soft'],
                  ),
                ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: narrow ? double.infinity : 140,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: p.text(14, null, FontWeight.w500)),
                      Text(hint, softWrap: false, style: p.text(12.5, p.muted)),
                    ],
                  ),
                ),
                ...controls,
              ],
            ),
            if (note != null) ...[
              const SizedBox(height: 8),
              Text(note, style: p.text(12, p.muted)),
            ],
          ],
        ),
      );
      final when = prefs.ratesFetchedAt == null
          ? '内置汇率'
          : (() {
              final date = DateTime.fromMillisecondsSinceEpoch(
                prefs.ratesFetchedAt!,
              );
              return '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')} 更新';
            })();
      return LensCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
              child: Text('显示', style: p.text(15, null, FontWeight.w600)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  row('外观', '浅色、深色或跟着系统走', [
                    segment(
                      '外观',
                      const {'light': '浅色', 'dark': '深色', 'system': '跟随系统'},
                      prefs.appearance,
                      (value) => unawaited(
                        c.setPreferences(
                          c.preferences.copyWith(appearance: value),
                        ),
                      ),
                    ),
                  ]),
                  row('数字单位', '大数字怎么缩写', [
                    segment(
                      '数字单位',
                      const {'chinese': '万 / 亿', 'english': 'K / M / B'},
                      prefs.unitSystem,
                      (value) => unawaited(
                        c.setPreferences(
                          c.preferences.copyWith(unitSystem: value),
                        ),
                      ),
                    ),
                    Text(
                      '例：${prefs.unitSystem == 'chinese' ? '18.2亿 token · 3700万 token' : '1.82B token · 37.0M token'}',
                      style: p.text(12.5, p.muted),
                    ),
                  ]),
                  row('货币', '金额用什么显示', [
                    segment(
                      '货币',
                      const {'USD': '美元 \$', 'CNY': '人民币 ¥'},
                      prefs.currency,
                      (value) => unawaited(
                        c.setPreferences(
                          c.preferences.copyWith(currency: value),
                        ),
                      ),
                    ),
                    Text(
                      '1 美元 ≈ ${rateFor(prefs.rates, 'CNY').toStringAsFixed(2)} 元 · $when',
                      style: p.text(12.5, p.muted),
                    ),
                    LensButton(
                      label: _operation == null ? '更新汇率' : '更新中…',
                      icon: Icons.refresh,
                      variant: 'ghost',
                      size: 'link',
                      spinning: _operation != null,
                      onPressed: _operation == null
                          ? () => unawaited(_refresh())
                          : null,
                    ),
                    if (_error != null)
                      Semantics(
                        liveRegion: true,
                        child: Text(_error!, style: p.text(12, p['danger'])),
                      ),
                  ], note: '只换显示，账本里的金额不变。汇率只在点「更新汇率」时联网取一次，失败就保留现在的值。'),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
