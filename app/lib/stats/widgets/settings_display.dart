import '../../l10n/app_strings.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../stats_controller.dart';
import '../logic/exchange_rate.dart';
import '../logic/format.dart';
import '../preferences.dart';
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
  Future<bool>? _shortcutExists;
  bool _creatingShortcut = false;
  bool? _shortcutCreated;
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
      _shortcutExists = null;
      _creatingShortcut = false;
      _shortcutCreated = null;
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

  Future<void> _createShortcut() async {
    if (_creatingShortcut) return;
    final controller = widget.controller;
    setState(() {
      _creatingShortcut = true;
      _shortcutCreated = null;
    });
    final created = await controller.gateway.createDesktopShortcut();
    if (!mounted || widget.controller != controller) return;
    setState(() {
      _creatingShortcut = false;
      _shortcutCreated = created;
      if (created) _shortcutExists = Future.value(true);
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final p = LensPalette.of(context), c = widget.controller;
      final prefs = c.preferences;
      final s = context.strings;
      final spacing = prefs.spacing;
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
        padding: EdgeInsets.symmetric(
          horizontal: 18 * spacing,
          vertical: 7 * spacing,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, bounds) {
                final description = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: p.text(14, null, FontWeight.w500)),
                    if (hint.isNotEmpty)
                      Text(hint, style: p.text(12.5, p.muted)),
                  ],
                );
                final actions = Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: controls,
                );
                return bounds.maxWidth < 530
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          description,
                          const SizedBox(height: 6),
                          actions,
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(flex: 2, child: description),
                          const SizedBox(width: 12),
                          Expanded(flex: 3, child: actions),
                        ],
                      );
              },
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
      Widget card(String title, List<Widget> rows) => LensCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                18 * spacing,
                12 * spacing,
                18 * spacing,
                2,
              ),
              child: Text(title, style: p.text(15, null, FontWeight.w600)),
            ),
            ...rows,
          ],
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          card(s.appearanceAndInterface, [
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
                    c.setPreferences(c.preferences.copyWith(appearance: value)),
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
                  c.setPreferences(c.preferences.copyWith(language: language)),
                ),
              ),
            ]),
            row(s.interfaceDensity, s.densityHint, [
              segment(
                s.interfaceDensity,
                {
                  'comfortable': s.comfortableDensity,
                  'compact': s.compactDensity,
                },
                prefs.density,
                (value) => unawaited(
                  c.setPreferences(c.preferences.copyWith(density: value)),
                ),
              ),
            ]),
            row(s.interfaceScale, s.interfaceScaleHint, [
              segment(
                s.interfaceScale,
                {
                  for (final scale in UiPreferences.interfaceScales)
                    '$scale': '${(scale * 100).round()}%',
                },
                '${prefs.uiScale}',
                (value) => unawaited(
                  c.setPreferences(
                    c.preferences.copyWith(uiScale: double.parse(value)),
                  ),
                ),
              ),
              if (prefs.uiScale != 1)
                LensButton(
                  label: s.resetInterfaceScale,
                  size: 'xs',
                  variant: 'ghost',
                  onPressed: () => unawaited(
                    c.setPreferences(c.preferences.copyWith(uiScale: 1)),
                  ),
                ),
            ]),
            if (c.gateway.shortcutGateway case final shortcut?
                when Theme.of(context).platform == TargetPlatform.windows)
              FutureBuilder<bool>(
                future: _shortcutExists ??= shortcut.desktopShortcutExists(),
                builder: (context, snapshot) =>
                    row(s.desktopShortcut, s.desktopShortcutHint, [
                      LensButton(
                        label: snapshot.data == true
                            ? s.desktopShortcutRecreate
                            : s.desktopShortcutCreate,
                        icon: Icons.desktop_windows_outlined,
                        variant: 'ghost',
                        size: 'xs',
                        spinning: _creatingShortcut,
                        onPressed:
                            _creatingShortcut ||
                                snapshot.connectionState != ConnectionState.done
                            ? null
                            : () => unawaited(_createShortcut()),
                      ),
                      if (_shortcutCreated case final created?)
                        Semantics(
                          liveRegion: true,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 4,
                            children: [
                              if (created)
                                Icon(Icons.check, size: 14, color: p['ok']),
                              Text(
                                created
                                    ? s.desktopShortcutCreated
                                    : s.desktopShortcutFailed,
                                style: p.text(12.5, p[created ? 'ok' : 'warn']),
                              ),
                            ],
                          ),
                        ),
                    ]),
              ),
          ]),
          SizedBox(height: MediaQuery.sizeOf(context).width < 768 ? 12 : 16),
          card(s.numbersAndTime, [
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
                    c.setPreferences(c.preferences.copyWith(unitSystem: value)),
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
              first: true,
            ),
            row(
              context.strings.currency,
              context.strings.currencyUsedToDisplayCosts,
              [
                segment(
                  context.strings.currency,
                  {'USD': context.strings.usd, 'CNY': context.strings.cny},
                  prefs.currency,
                  (value) => unawaited(
                    c.setPreferences(c.preferences.copyWith(currency: value)),
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
                  size: 'xs',
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
            row(s.defaultPeriod, s.defaultPeriodHint, [
              segment(
                s.defaultPeriod,
                {
                  'last': s.lastUsedPeriod,
                  'today': s.today,
                  'week': s.thisWeek2,
                  'month': s.thisMonth2,
                },
                prefs.defaultPeriod,
                (value) => unawaited(
                  c.setPreferences(
                    c.preferences.copyWith(defaultPeriod: value),
                  ),
                ),
              ),
            ]),
            row(s.weekStartsOn, s.weekStartsOnHint, [
              segment(
                s.weekStartsOn,
                {'monday': s.monday, 'sunday': s.sunday},
                prefs.weekStart,
                (value) => unawaited(
                  c.setPreferences(c.preferences.copyWith(weekStart: value)),
                ),
              ),
            ]),
          ]),
        ],
      );
    },
  );
}
