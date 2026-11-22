import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';
import '../../stats_controller.dart';
import '../../stats_gateway.dart';
import '../logic/format.dart';
import '../logic/pricing_display.dart';
import '../logic/tools.dart';
import '../preferences.dart';
import '../theme/palette.dart';
import 'primitives.dart';

Future<void> showManualPriceDialog(
  BuildContext context, {
  required StatsController controller,
  required StatsPricing pricing,
  required StatsModelPrice model,
  required StatsBreakdown? usage,
}) async {
  final id = model.model;
  if (id == null || id.trim().isEmpty) return;
  final groups =
      usage?.groups.where((g) => g.model == id) ?? const <StatsGroup>[];
  final tokens = [0, 0, 0, 0];
  final tools = <String>{};
  for (final group in groups) {
    final kinds = [
      group.inputTokens,
      group.outputTokens,
      group.cacheReadTokens,
      group.cacheWriteTokens,
    ];
    for (var i = 0; i < kinds.length; i++) {
      tokens[i] += kinds[i] ?? 0;
    }
    if (group.source case final source?) tools.add(toolOf(source).name);
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ListenableBuilder(
      listenable: controller,
      builder: (_, _) => _ManualPriceDialog(
        model: id,
        tools: tools.join(context.strings.listSeparator),
        records: model.records,
        tokens: tokens,
        preferences: controller.preferences,
        manual: model.manual,
        choices: pricing.copyPrices,
        save: controller.saveManualPrice,
      ),
    ),
  );
}

class _ManualPriceDialog extends StatefulWidget {
  const _ManualPriceDialog({
    required this.model,
    required this.tools,
    required this.records,
    required this.tokens,
    required this.preferences,
    required this.manual,
    required this.choices,
    required this.save,
  });

  final String model, tools;
  final int records;
  final List<int> tokens;
  final UiPreferences preferences;
  final StatsManualPrice? manual;
  final List<StatsCopyPrice> choices;
  final Future<void> Function(String) save;

  @override
  State<_ManualPriceDialog> createState() => _ManualPriceDialogState();
}

class _ManualPriceDialogState extends State<_ManualPriceDialog> {
  late String currency = widget.manual?.currency ?? 'USD';
  late final fields = _items(widget.manual?.original)
      .map((v) => TextEditingController(text: _numericText(v)))
      .toList();
  late final note = TextEditingController(text: widget.manual?.note);
  String copy = '';
  bool checkingFields = false, saving = false;
  Object? error;

  static List<double?> _items(StatsPrices? value) => [
    value?.input,
    value?.output,
    value?.cacheRead,
    value?.cacheWrite5M,
  ];
  static String _numericText(double? value) =>
      value?.toString().replaceFirst(RegExp(r'\.0$'), '') ?? '';
  String get count => recordText(widget.records);
  double get exchange => rateFor(widget.preferences.rates, 'CNY');

  double? _number(int i) {
    final v = double.tryParse(fields[i].text.trim());
    return v != null && v.isFinite && v >= 0 ? v : null;
  }

  String? _fieldError(int i, AppStrings s) {
    if (fields[i].text.trim().isEmpty) {
      return i < 2 ? s.manualPriceRequired : null;
    }
    return _number(i) == null ? s.manualPriceNonnegative : null;
  }

  void _copy(String? id) {
    if (id == null) return;
    setState(() {
      copy = id;
      error = null;
      if (id.isEmpty) return;
      final choice = widget.choices.firstWhere((item) => item.id == id);
      final values = _items(choice.prices);
      for (var i = 0; i < values.length; i++) {
        fields[i].text = _numericText(values[i]);
      }
      currency = 'USD';
      if (note.text.trim().isEmpty) {
        note.text = context.strings.copiedPriceSource(id);
      }
    });
  }

  Future<void> _save() async {
    if (saving) return;
    setState(() {
      checkingFields = true;
      error = null;
    });
    if (List.generate(
      4,
      (i) => _fieldError(i, context.strings),
    ).any((e) => e != null)) {
      return;
    }
    setState(() => saving = true);
    try {
      await widget.save(
        jsonEncode({
          'model': widget.model,
          'currency': currency,
          if (currency == 'CNY') 'rate': exchange,
          'input': _number(0),
          'output': _number(1),
          'cacheRead': _number(2),
          'cacheWrite': _number(3),
          'note': note.text.trim().isEmpty ? null : note.text.trim(),
        }),
      );
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = failure;
          saving = false;
        });
      }
    }
  }

  @override
  void dispose() {
    for (final field in fields) {
      field.dispose();
    }
    note.dispose();
    super.dispose();
  }

  List<String> _labels(AppStrings s) => [
    s.manualNewInput,
    s.output,
    s.manualCacheRead,
    s.manualCacheWrite,
  ];

  String _estimate(AppStrings s) {
    final prices = List.generate(widget.tokens.length, _number);
    if (prices[0] == null || prices[1] == null) {
      return s.manualEstimatePending(count);
    }
    final display = widget.preferences.currency;
    final rate = rateFor(widget.preferences.rates, display);
    final divisor = currency == 'CNY' ? exchange : 1.0;
    String money(double value) {
      final usd = value / divisor;
      return usdCurrency(
        usd,
        currency: display,
        rate: rate,
        decimals: moneyDecimals(usd * rate),
      );
    }

    final labels = _labels(s);
    final parts = <String>[];
    var total = 0.0;
    for (var i = 0; i < prices.length; i++) {
      final price = prices[i];
      final tokens = widget.tokens[i];
      if (tokens <= 0 || price == null) continue;
      final amount = tokens / 1e6 * price;
      total += amount;
      parts.add('${labels[i]} ${money(amount)}');
    }
    return s.manualEstimate(count, money(total), parts.join(' · '));
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context), s = context.strings;
    final subtitle = s.manualPriceSubtitle(
      widget.model,
      widget.tools.isEmpty ? '—' : widget.tools,
      count,
    );
    final labels = _labels(s);
    Widget field(int i) {
      final label = i < 2 ? labels[i] : '${labels[i]} · ${s.manualOptional}';
      final validation = checkingFields ? _fieldError(i, s) : null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 4,
        children: [
          Text(label, style: p.text(12.5, p.secondary)),
          LensInput(
            key: ValueKey('manual-price-$i'),
            label: label,
            autofocus: i == 0,
            enabled: !saving,
            error: validation != null,
            controller: fields[i],
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            onChanged: (_) => setState(() {
              copy = '';
              error = null;
            }),
          ),
          if (validation != null)
            Semantics(
              liveRegion: true,
              child: Text(validation, style: p.text(12, p['danger'])),
            ),
        ],
      );
    }

    Widget secondary(String text) => Text(text, style: p.text(12.5, p.muted));
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              if (!saving) Navigator.pop(context);
              return null;
            },
          ),
        },
        child: Dialog(
          backgroundColor: p.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(LensTokens.radii['2xl']!),
          ),
          child: SizedBox(
            width: 508,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 10,
                children: [
                  Semantics(
                    namesRoute: true,
                    child: Text(
                      s.addPrice,
                      style: p.text(18, null, FontWeight.w600),
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 10,
                        children: [
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: widget.model,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                TextSpan(
                                  text: subtitle.substring(widget.model.length),
                                ),
                              ],
                            ),
                            style: p.text(13, p.secondary),
                          ),
                          if (widget.manual == null)
                            Text(
                              s.manualPriceIntro,
                              style: p.text(13, p.secondary),
                            ),
                          InputDecorator(
                            decoration: InputDecoration(
                              labelText: s.copyPricesFrom,
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                key: const ValueKey('manual-price-copy'),
                                isExpanded: true,
                                isDense: true,
                                value: copy,
                                onChanged: saving ? null : _copy,
                                items: [
                                  DropdownMenuItem(
                                    value: '',
                                    child: Text(s.copyPricesNone),
                                  ),
                                  for (final choice in widget.choices)
                                    DropdownMenuItem(
                                      value: choice.id,
                                      child: Text(
                                        choice.baseOnly
                                            ? '${choice.id} ${s.copyBaseOnly}'
                                            : choice.id,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          secondary(s.copyPricesHelp),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: LensSegmented(
                              options: {'USD': s.manualUsd, 'CNY': s.manualCny},
                              value: currency,
                              label: s.currency,
                              small: true,
                              onChanged: (value) {
                                if (!saving) {
                                  setState(() {
                                    currency = value;
                                    copy = '';
                                    error = null;
                                  });
                                }
                              },
                            ),
                          ),
                          Column(
                            spacing: 10,
                            children: MediaQuery.sizeOf(context).width < 480
                                ? [for (var i = 0; i < 4; i++) field(i)]
                                : [
                                    for (var i = 0; i < 4; i += 2)
                                      Row(
                                        spacing: 10,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(child: field(i)),
                                          Expanded(child: field(i + 1)),
                                        ],
                                      ),
                                  ],
                          ),
                          secondary(s.manualPriceUnit),
                          Text(
                            s.manualSource,
                            style: p.text(12.5, p.secondary),
                          ),
                          LensInput(
                            controller: note,
                            enabled: !saving,
                            maxLength: 500,
                            label: s.manualSource,
                            hint: s.manualSourceHint,
                          ),
                          LensCard(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                spacing: 4,
                                children: [
                                  Text(
                                    _estimate(s),
                                    style: p.text(13, p.secondary),
                                  ),
                                  if (_number(0) != null &&
                                      _number(1) != null &&
                                      fields[2].text.trim().isEmpty)
                                    secondary(s.manualNoCacheRead),
                                  if (currency == 'CNY')
                                    secondary(
                                      s.manualSavedAtRate(
                                        exchange.toStringAsFixed(2),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          secondary(s.manualPriceFootnote),
                          if (error case final failure?)
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                s.requestFailed0(failure),
                                style: p.text(13, p['danger']),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      LensButton(
                        label: s.cancel,
                        onPressed: saving ? null : () => Navigator.pop(context),
                      ),
                      LensButton(
                        label: s.saveManual,
                        variant: 'primary',
                        onPressed: saving ? null : _save,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
