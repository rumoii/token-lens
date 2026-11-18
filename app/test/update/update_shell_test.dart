import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/preferences.dart';
import 'package:token_lens_app/stats/settings_page.dart';
import 'package:token_lens_app/stats/stats_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats_controller.dart';
import 'package:token_lens_app/stats_gateway.dart';
import 'package:token_lens_app/update/update_check.dart';

import '../stats/fake_gateway.dart';
import 'update_check_test.dart' show NoUpdateNetwork;

class VersionGateway extends FakeStatsGateway {
  @override
  Future<StatsHealth> health() async => const StatsHealth(
    ok: true,
    version: '0.1.0',
    dataDir: '/synthetic',
    ledgerPath: '/synthetic/ledger.db',
    schemaVersion: 6,
  );
}

void main() {
  for (final width in [1440.0, 1024.0, 720.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'all pages share hint and navigate/scroll to update; drawer included $width $dark',
        (t) async {
          final network = NoUpdateNetwork();
          HttpOverrides.global = network;
          addTearDown(() {
            expect(network.calls, 0);
            HttpOverrides.global = null;
          });
          t.view.devicePixelRatio = 1;
          t.view.physicalSize = Size(width, 900);
          addTearDown(t.view.resetDevicePixelRatio);
          addTearDown(t.view.resetPhysicalSize);
          final c = StatsController(
            VersionGateway(),
            preferences: UiPreferences(
              onboarded: true,
              updateLastAttemptMs: demoNow.millisecondsSinceEpoch,
              updateResult: const UpdateResult(
                UpdateKind.available,
                version: '0.2.0',
              ),
            ),
            clock: () => demoNow,
            updateRequest: (_, _, _) async => const UpdateResponse(404, ''),
          );
          addTearDown(c.dispose);
          await c.load();
          await c.health();
          await t.pumpWidget(
            MaterialApp(
              theme: LensPalette(dark).theme,
              home: StatsPage(
                controller: c,
                news: const Text('synthetic news'),
              ),
            ),
          );
          await t.pumpAndSettle();
          final state = t.state(find.byType(StatsPage)) as dynamic;
          for (final page in [
            'home',
            'detail',
            'sessions',
            'sources',
            'news',
            'settings',
          ]) {
            state.navigate(page);
            await t.pumpAndSettle();
            if (width < 768) {
              await t.tap(find.byTooltip('打开导航菜单'));
              await t.pumpAndSettle();
            }
            expect(find.byKey(const Key('update-hint')), findsOneWidget);
            expect(t.takeException(), isNull);
          }
          await t.tap(find.byKey(const Key('update-hint-open')));
          await t.pumpAndSettle();
          expect(find.byType(StatsSettingsPage), findsOneWidget);
          final card = t.getRect(find.byKey(const Key('update-card')));
          expect(card.top, greaterThanOrEqualTo(0));
          expect(card.bottom, lessThanOrEqualTo(900));
          final scroll = t
              .widget<SingleChildScrollView>(
                find.byKey(const Key('stats-scroll')),
              )
              .controller!;
          expect(scroll.offset, greaterThan(0));
          expect(
            find.byWidgetPredicate(
              (w) => w is ScrollView && w.scrollDirection == Axis.horizontal,
            ),
            findsNothing,
          );
          if (width < 768) {
            await t.tap(find.byTooltip('打开导航菜单'));
            await t.pumpAndSettle();
          }
          await t.tap(find.byKey(const Key('update-hint-dismiss')));
          await t.pumpAndSettle();
          expect(c.preferences.updateIgnoredVersion, '0.2.0');
          expect(c.updates.showHint, false);
          expect(find.byKey(const Key('update-hint')), findsNothing);
          await t.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
