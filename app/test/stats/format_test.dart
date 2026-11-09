import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/format.dart';

class _Note {
  @override
  String toString() => ' note ';
}

void main() {
  group('format.test.ts', () {
    test('缺失、零、大整数、文本各自保留', () {
      expect(
        [toDisplayNumber(null), toDisplayNumber(null), toDisplayNumber(0)],
        ['-', '-', '0'],
      );
      final exact = BigInt.parse('874123456789012345678901');
      expect(toDisplayNumber(exact), '874,123,456,789,012,345,678,901');
      expect(
        toDisplayNumber(' 000874123456789012345678901 '),
        toDisplayNumber(exact),
      );
      expect(toDisplayNumber(' -1530.4 '), '-1530.4');
      expect(toDisplayNumber(double.nan), 'NaN');
      expect(toDisplayNumber(double.infinity), '∞');
      expect(toDisplayNumber(_Note()), 'note');
    });
    test('国际单位与进位', () {
      for (final p in <(num, String)>[
        (730, '730'),
        (28765, '28.8K'),
        (-6204000, '-6.2M'),
        (4.78e9, '4.8B'),
        (3.14e12, '3.1T'),
        (999950, '1M'),
        (999950000, '1B'),
        (999950000000, '1T'),
      ]) {
        expect(compactNumber(p.$1), p.$2);
      }
      expect(compactNumber('  '), '0');
      expect(compactNumber(-0.0), '0');
      expect(compactNumber(12345, decimals: double.negativeInfinity), '12K');
      expect(compactNumber(12345, decimals: double.nan), '12K');
      expect(compactNumber(12345, decimals: double.infinity), '12.345K');
      expect(compactNumber(1234567, decimals: 2.9), '1.23M');
      const suffixes = ['kilo', 'mega', 'giga', 'tera'];
      expect(
        [1e3, 1e6, 1e9, 1e12].map((n) => compactNumber(n, suffixes: suffixes)),
        ['1kilo', '1mega', '1giga', '1tera'],
      );
      expect(compactNumber(double.maxFinite), contains('T'));
    });
    test('中文精度与有符号小零', () {
      for (final p in <(num, String)>[
        (9999.4, '9,999'),
        (9999.5, '1万'),
        (28640, '2.9万'),
        (73460000, '7346万'),
        (563000000, '5.6亿'),
        (99999999, '1亿'),
        (999999999999, '1万亿'),
        (-.2, '-0'),
        (-0.0, '0'),
        (1.234e12, '1.2万亿'),
      ]) {
        expect(chineseNumber(p.$1, decimals: 6), p.$2);
        expect(chineseNumber(p.$1, decimals: 0), p.$2);
      }
      expect(chineseNumber(double.maxFinite), contains('万亿'));
    });
    test('非法缩写不当零', () {
      for (final value in [null, double.nan, double.infinity, 'twelve']) {
        expect(compactNumber(value), '-');
        expect(chineseNumber(value), '-');
      }
    });
    test('金额先六位舍入再截断，只换算有效 CNY', () {
      expect(usdCurrency(-26.875), '-\$26.87');
      expect(usdCurrency(8.764321, decimals: 4), '\$8.7643');
      expect(usdCurrency(2.9999999), '\$3.00');
      expect(usdCurrency(12, currency: 'CNY', rate: 7.43), '¥89.16');
      expect(usdCurrency(3, currency: 'EUR', rate: 10), '\$3.00');
      expect(usdCurrency(3, currency: 'USD', rate: 10), '\$3.00');
      for (final rate in [0, -1, double.nan, double.infinity]) {
        expect(usdCurrency(3, currency: 'CNY', rate: rate), '¥3.00');
      }
      expect(
        usdCurrency(BigInt.from(5), decimals: double.infinity),
        '\$5.000000',
      );
      expect(usdCurrency(5, decimals: double.nan), '\$5');
      expect(usdCurrency(-1e25), '\$-1e+25');
      expect(
        usdCurrency(double.maxFinite, currency: 'CNY', rate: 10),
        contains('Infinity'),
      );
      expect(
        [
          usdCurrency(null),
          usdCurrency('  '),
          usdCurrency('oops'),
          usdCurrency(double.nan),
        ],
        ['-', '-', 'oops', 'NaN'],
      );
    });
  });
  group('token-format.test.js', () {
    test('纯格式默认英文，可选中文、完整与提示', () {
      expect(tokenCount(2867000), '2.9M');
      expect(tokenCount(2867000, unitSystem: 'chinese'), '287万');
      expect(tokenCount(2867000, mode: 'chinese'), '287万');
      expect(
        tokenCount(2867000, unitSystem: 'chinese', mode: 'full'),
        '2,867,000',
      );
      expect(
        tokenCount(2867000, mode: 'chinese', forceFull: true),
        '2,867,000',
      );
      expect(tokenTooltip(2867000), '2.9M · 2,867,000');
      expect(tokenTooltip(27), '27');
      expect(tokenTooltip(null), '-');
      expect(tokenTooltip(double.nan), 'NaN');
      expect(tokenTooltip(2867000, mode: 'full'), '2,867,000');
      expect(tokenCount(-2500, suffixes: ['kilo', 'M', 'B', 'T']), '-2.5kilo');
    });
  });
  group('currency.test.ts 纯逻辑', () {
    test('限制币种并兼容失效旧值', () {
      for (final old in ['EUR', 'JPY', 'GBP', 'HKD', '', 'nonsense']) {
        expect(normalizeCurrency(old), 'USD');
      }
      expect(normalizeCurrency(' cny '), 'CNY');
      expect(currencySymbol('usd'), '\$');
      expect(currencySymbol(' CNY'), '¥');
    });
    test('只接受正有限数字汇率', () {
      for (final invalid in ['7.8', 0, -3, double.nan, double.infinity, null]) {
        expect(isValidRate(invalid), isFalse);
      }
      expect(isValidRate(7.8), isTrue);
      expect(rateFor({'USD': 400, 'CNY': 7.8}, 'USD'), 1);
      expect(rateFor({'CNY': 0}, 'CNY'), 6.7);
      expect(applyCurrency(13, 'CNY', {'CNY': 8}), (value: 104.0, symbol: '¥'));
      expect(applyCurrency(13, 'EUR', null), (value: 13.0, symbol: '\$'));
    });
  });
  group('currency-rate.test.ts', () {
    test('固定 CNY 6.7', () => expect(defaultRates['CNY'], 6.7));
    test(
      '人民币换算符号',
      () => expect(
        usdCurrency('10.00', currency: 'CNY', rate: defaultRates['CNY']),
        '¥67.00',
      ),
    );
    test('USD 不受误传汇率影响', () {
      expect(usdCurrency('10.00'), '\$10.00');
      expect(
        usdCurrency('10.00', currency: 'USD', rate: defaultRates['CNY']),
        '\$10.00',
      );
    });
    test('空金额不是零', () {
      expect(usdCurrency(null, currency: 'CNY', rate: 6.7), '-');
      expect(usdCurrency('  ', currency: 'CNY', rate: 6.7), '-');
    });
  });
}
