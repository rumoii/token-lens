import '../../l10n/app_strings.dart';

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
  Object? _error;
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
        setState(() => _error = failure);
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
        bool first = false,
      }) => Container(
        decoration: BoxDecoration(
          border: first
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
                      if (hint.isNotEmpty)
                        Text(hint, style: p.text(12.5, p.muted)),
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
          ? context.strings.builtInRate
          : (() {
              final date = DateTime.fromMillisecondsSinceEpoch(
                prefs.ratesFetchedAt!,
              );
              return context.strings.rateUpdatedAt(
                date.month,
                date.day,
                date.hour.toString().padLeft(2, '0'),
                date.minute.toString().padLeft(2, '0'),
              );
            })();
      return LensCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
              child: Text(
                context.strings.display,
                style: p.text(15, null, FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  row(
                    context.strings.appearance,
                    context.strings.lightDarkOrSystemTheme,
                    [
                      segment(
                        context.strings.appearance,
                        {
                          'light': context.strings.light,
                          'dark': context.strings.dark,
                          'system': context.strings.followSystem,
                        },
                        prefs.appearance,
                        (value) => unawaited(
                          c.setPreferences(
                            c.preferences.copyWith(appearance: value),
                          ),
                        ),
                      ),
                    ],
                    first: true,
                  ),
                  row(context.strings.interfaceLanguage, '', [
                    segment(
                      context.strings.interfaceLanguage,
                      {
                        'system': context.strings.followSystem,
                        'zh': context.strings.chineseLanguage,
                        'en': context.strings.englishLanguage,
                      },
                      prefs.language,
                      (language) => unawaited(
                        c.setPreferences(
                          c.preferences.copyWith(language: language),
                        ),
                      ),
                    ),
                  ]),
                  row(
                    context.strings.numberUnits,
                    context.strings.howLargeNumbersAreShortened,
                    [
                      segment(
                        context.strings.numberUnits,
                        {
                          'chinese': context.strings.chineseNumberUnits,
                          'english': 'K / M / B',
                        },
                        c.unitSystem,
                        (value) => unawaited(
                          c.setPreferences(
                            c.preferences.copyWith(unitSystem: value),
                          ),
                        ),
                      ),
                      Text(
                        context.strings.example0(
                          c.unitSystem == 'chinese'
                              ? context.strings.chineseNumberExample
                              : context.strings.englishNumberExample,
                        ),
                        style: p.text(12.5, p.muted),
                      ),
                    ],
                  ),
                  row(
                    context.strings.currency,
                    context.strings.currencyUsedToDisplayCosts,
                    [
                      segment(
                        context.strings.currency,
                        {
                          'USD': context.strings.usd,
                          'CNY': context.strings.cny,
                        },
                        prefs.currency,
                        (value) => unawaited(
                          c.setPreferences(
                            c.preferences.copyWith(currency: value),
                          ),
                        ),
                      ),
                      Text(
                        context.strings.exchangeRate(
                          rateFor(prefs.rates, 'CNY').toStringAsFixed(2),
                          when,
                        ),
                        style: p.text(12.5, p.muted),
                      ),
                      LensButton(
                        label: _operation == null
                            ? context.strings.updateRate
                            : context.strings.updating,
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
                          child: Text(
                            context.strings.exchangeRateUpdateFailed(_error),
                            style: p.text(12, p['danger']),
                          ),
                        ),
                    ],
                    note: context.strings.displayOnlyLedgerAmountsStayTheSame,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
