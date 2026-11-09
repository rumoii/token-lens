import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets('基础组件 ${dark ? 'dark' : 'light'}', (tester) async {
      var selected = '';
      await tester.pumpWidget(
        MaterialApp(
          theme: LensPalette(dark).theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: Column(
              children: [
                LensCard(child: const Text('面板')),
                LensSegmented(
                  options: const {'a': '甲', 'b': '乙'},
                  value: 'a',
                  onChanged: (v) => selected = v,
                  label: '切换',
                ),
                LensButton(label: '同步用量', onPressed: () {}),
                const LensBadge('已核验', tone: 'ok'),
                const ToolTile('aider'),
                const ToolTile('claude'),
                const BrandMark(),
                const TokenText(null),
                const MoneyText(null),
                const MoneyText(0),
                const StatTile(label: '会话', value: Text('1')),
                const EmptyState(title: '没有用量'),
                const SkeletonLines(),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('—'), findsOneWidget);
      expect(find.text('未定价'), findsOneWidget);
      expect(find.text('\$0.00'), findsOneWidget);
      await tester.tap(find.text('乙'));
      expect(selected, 'b');
      expect(tester.takeException(), isNull);
    });
  }
}
