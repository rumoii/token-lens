import 'dart:math' as math;

const defaultRates = {'USD': 1.0, 'CNY': 6.7};
String normalizeCurrency(Object? value, {String fallback = 'USD'}) =>
    switch (value is String ? value.trim().toUpperCase() : null) {
      'CNY' => 'CNY',
      'USD' => 'USD',
      _ => fallback,
    };
String currencySymbol(Object? value) =>
    normalizeCurrency(value) == 'CNY' ? '¥' : '\$';
bool isValidRate(Object? value) => value is num && value.isFinite && value > 0;
double rateFor(Map<String, num>? rates, Object? currency) =>
    normalizeCurrency(currency) == 'USD'
    ? 1
    : isValidRate(rates?['CNY'])
    ? rates!['CNY']!.toDouble()
    : defaultRates['CNY']!;
({double value, String symbol}) applyCurrency(
  num usd,
  Object? currency,
  Map<String, num>? rates,
) => (value: usd * rateFor(rates, currency), symbol: currencySymbol(currency));
String _group(String text) =>
    text.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
String _numberText(num value) {
  if (value.isNaN) return 'NaN';
  if (!value.isFinite) return value.isNegative ? '-Infinity' : 'Infinity';
  if (value == 0) return '0';
  if (value.abs() < 1e21 && value == value.truncateToDouble()) {
    return value.toInt().toString();
  }
  return value.toString().replaceFirst(RegExp(r'\.0(?=e|$)'), '');
}

String toDisplayNumber(Object? value) {
  if (value == null) return '-';
  final text = value.toString().trim();
  if (value is num) {
    if (!value.isFinite) {
      return value.isNaN
          ? 'NaN'
          : value.isNegative
          ? '-∞'
          : '∞';
    }
    final parts = _numberText(value).split('.');
    return _group(parts.first) + (parts.length > 1 ? '.${parts[1]}' : '');
  }
  if (value is BigInt || RegExp(r'^\d+$').hasMatch(text)) {
    return _group(BigInt.parse(text).toString());
  }
  return text;
}

double _numeric(Object? value) => value == null
    ? double.nan
    : value.toString().trim().isEmpty
    ? 0
    : double.tryParse(value.toString().trim()) ?? double.nan;
int _digits(num value) => value.isNaN || value == double.negativeInfinity
    ? 0
    : value == double.infinity
    ? 6
    : value.floor().clamp(0, 6);
String _fixed(num value, int places) {
  final text = value.toStringAsFixed(places);
  return text.contains('.') && !text.contains('e')
      ? text.replaceFirst(RegExp(r'\.?0+$'), '')
      : text;
}

String compactNumber(
  Object? value, {
  num decimals = 1,
  List<String> suffixes = const ['K', 'M', 'B', 'T'],
}) {
  final number = _numeric(value);
  if (!number.isFinite) return '-';
  final amount = number.abs();
  if (amount < 1000) return _numberText(number);
  var level = math.min(3, (math.log(amount) / math.ln10 / 3).floor() - 1);
  final precision = _digits(decimals);
  var coefficient = double.parse(
    (amount / math.pow(1000, level + 1)).toStringAsFixed(precision),
  );
  if (coefficient >= 1000 && level < 3) {
    coefficient = amount / math.pow(1000, ++level + 1);
  }
  return '${number < 0 ? '-' : ''}${_fixed(coefficient, precision)}${suffixes[level]}';
}

String chineseNumber(Object? value, {num decimals = 1}) {
  final number = _numeric(value);
  if (!number.isFinite) return '-';
  final amount = number.abs();
  final sign = number < 0 ? '-' : '';
  if (amount.roundToDouble() < 10000) {
    return sign + _group(amount.round().toString());
  }
  const bases = [1e4, 1e8, 1e12];
  const labels = ['万', '亿', '万亿'];
  var level = amount >= 1e12
      ? 2
      : amount >= 1e8
      ? 1
      : 0;
  var coefficient = amount / bases[level];
  var precision = level == 2 || coefficient < 100 ? 1 : 0;
  if (double.parse(coefficient.toStringAsFixed(precision)) >= 10000 &&
      level < 2) {
    coefficient = amount / bases[++level];
    precision = level == 2 || coefficient < 100 ? 1 : 0;
  }
  return sign + _fixed(coefficient, precision) + labels[level];
}

int moneyDecimals(num converted) => converted > 0 && converted < .01 ? 4 : 2;

String usdCurrency(
  Object? value, {
  num decimals = 2,
  Object? currency,
  num? rate,
}) {
  if (value == null || value.toString().trim().isEmpty) return '-';
  final number = _numeric(value);
  if (!number.isFinite) return value.toString().trim();
  final code = normalizeCurrency(currency);
  final converted = number * (code == 'CNY' && isValidRate(rate) ? rate! : 1);
  final symbol = currencySymbol(code);
  if (!converted.isFinite || converted.abs() >= 1e21) {
    return symbol + _numberText(converted);
  }
  final precision = _digits(decimals);
  final parts = converted.abs().toStringAsFixed(6).split('.');
  return '${converted < 0 ? '-' : ''}$symbol${_group(parts.first)}${precision > 0 ? '.${parts.last.substring(0, precision)}' : ''}';
}

String normalizeTokenMode(Object? value) =>
    value == 'full' ? 'full' : 'compact';
String normalizeTokenUnit(Object? value) =>
    value == 'chinese' ? 'chinese' : 'english';
String tokenCount(
  Object? value, {
  String mode = 'compact',
  String unitSystem = 'english',
  bool forceFull = false,
  List<String> suffixes = const ['K', 'M', 'B', 'T'],
}) => forceFull || normalizeTokenMode(mode) == 'full'
    ? toDisplayNumber(value)
    : unitSystem == 'chinese' || mode == 'chinese'
    ? chineseNumber(value)
    : compactNumber(value, suffixes: suffixes);
String tokenTooltip(
  Object? value, {
  String mode = 'compact',
  String unitSystem = 'english',
}) {
  final full = toDisplayNumber(value);
  final short = tokenCount(value, mode: mode, unitSystem: unitSystem);
  return full == short || full == '-' || short == '-' ? full : '$short · $full';
}

String percentage(num? ratio) {
  if (ratio == null || !ratio.isFinite) return '—';
  final value = ratio * 100;
  if (value == 0 || value == 100) return '${value.toInt()}%';
  final rounded = value.round();
  if (value > 0 && value < 100 && (rounded == 0 || rounded == 100)) {
    return '${value.clamp(.1, 99.9).toStringAsFixed(1)}%';
  }
  return '$rounded%';
}

/// Keep a short ending together so a final word or character does not stand alone.
String keepTailTogether(String text) {
  final runes = text.runes.toList();
  if (runes.length <= 1) return text;
  final tail = math.max(0, runes.length - 4);
  return String.fromCharCodes(runes.take(tail)) +
      runes.skip(tail).map(String.fromCharCode).join('\u2060');
}
