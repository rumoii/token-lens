import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/app_shell.dart';
import 'package:token_lens_app/l10n/app_strings.dart';
import 'package:token_lens_app/src/rust/api/diagnostics.dart' as diagnostics;
import 'package:token_lens_app/src/rust/api/stats.dart' as native;
import 'package:token_lens_app/src/rust/frb_generated.dart';
import 'package:token_lens_app/startup_failure.dart';
import 'package:token_lens_app/startup_failure_page.dart';
import 'package:token_lens_app/stats/theme/palette.dart';
import 'package:token_lens_app/stats/widgets/primitives.dart';
import 'package:token_lens_app/stats/widgets/sidebar.dart';

const _exportPath = 'downloads/token-lens-diagnostics-20261120-093100.txt';

StartupFailureCard card(
  StartupErrorCode code, {
  bool full = true,
  bool newsEnabled = false,
  Future<String> Function()? export,
  Future<bool> Function(Uri)? openLink,
}) => StartupFailureCard(
  failure: StartupFailure(
    code,
    'test error',
    ledgerVersion: 12,
    supportedVersion: 7,
  ),
  dataDir: 'test/data',
  version: '0.1.0 (abc123) · Test OS',
  logDirectory: 'test/data/logs',
  appDirectory: 'test/app',
  exportDiagnostics: export ?? () async => _exportPath,
  openLink: openLink ?? (_) async => true,
  onClose: full ? () {} : null,
  newsEnabled: newsEnabled,
);

Widget host(Widget child, {AppStrings strings = englishStrings}) => MaterialApp(
  theme: const LensPalette(false).theme,
  builder: (_, page) => AppLanguageScope(strings: strings, child: page!),
  home: child,
);

LensButton button(WidgetTester tester, String label) =>
    tester.widget(find.widgetWithText(LensButton, label));

void main() {
  test('real FFI startup errors drive the ledger-free export', () async {
    await RustLib.init();
    final root = await Directory.systemTemp.createTemp('token-lens-s6a-');
    addTearDown(() => root.delete(recursive: true));
    String path(String name) => '${root.path}${Platform.pathSeparator}$name';
    final ledger = File(path('ledger.db'));
    await ledger.writeAsString('not a ledger');
    late final StartupFailure failure;
    try {
      await native.StatsClient.newInstance(
        dataDir: root.path,
        logsHome: root.path,
      );
      fail('The fixture must fail to open.');
    } on String catch (error) {
      failure = parseStartupFailure(error);
    }
    expect(failure.code, StartupErrorCode.ledgerCorrupt);
    final exported = await diagnostics.exportStartupDiagnostics(
      dataDir: root.path,
      logsHome: root.path,
      directory: path('exports'),
      errorCode: failure.code.wire,
      message: failure.message,
    );
    final text = await File(exported).readAsString();
    expect(text, contains('账本：无法打开（ledger_corrupt）'));
    expect(text, isNot(contains(root.path)));
    expect(await ledger.readAsString(), 'not a ledger');
  });

  final cases = [
    (
      'already_running',
      StartupErrorCode.alreadyRunning,
      'Token Lens is already running',
      'Close',
    ),
    (
      'app_files_missing',
      StartupErrorCode.appFilesMissing,
      'App files are incomplete',
      'Open app folder',
    ),
    (
      'data_dir_denied',
      StartupErrorCode.dataDirDenied,
      'No permission to use the data folder',
      'Export diagnostics',
    ),
    ('disk_full', StartupErrorCode.diskFull, 'Not enough disk space', 'Close'),
    (
      'ledger_corrupt',
      StartupErrorCode.ledgerCorrupt,
      'The usage ledger is damaged',
      'Export diagnostics',
    ),
    (
      'ledger_too_new',
      StartupErrorCode.ledgerTooNew,
      'The ledger is from a newer Token Lens',
      'Close',
    ),
    (
      'startup_failed',
      StartupErrorCode.startupFailed,
      'Token Lens could not start',
      'Export diagnostics',
    ),
  ];
  test(
    'parses only recognized prefix codes and includes both ledger versions',
    () {
      for (final (wire, code, _, _) in cases) {
        final text = wire == 'ledger_too_new'
            ? '$wire:12:7: test error'
            : '$wire: test error';
        final failure = parseStartupFailure(text);
        expect(failure.code, code);
        expect(failure.message, 'test error');
        if (code == StartupErrorCode.ledgerTooNew) {
          expect(failure.ledgerVersion, 12);
          expect(failure.supportedVersion, 7);
        }
      }
      for (final unknown in [
        'unknown: error',
        'StateError: disk_full: detail',
        'busy: Cache directory is in use.',
      ]) {
        expect(
          parseStartupFailure(unknown).code,
          StartupErrorCode.startupFailed,
        );
        expect(parseStartupFailure(unknown).message, unknown);
      }
    },
  );

  for (final (wire, code, title, primary) in cases) {
    testWidgets('startup page presents $wire with its primary action', (
      tester,
    ) async {
      await tester.pumpWidget(host(StartupFailurePage(card: card(code))));
      expect(find.text(title), findsOneWidget);
      expect(button(tester, primary).variant, 'primary');
      if (code == StartupErrorCode.appFilesMissing) {
        expect(find.text('Export diagnostics'), findsNothing);
        expect(find.text('Open log folder'), findsNothing);
      } else {
        expect(button(tester, 'Open log folder').variant, 'secondary');
        expect(
          button(tester, 'Export diagnostics').variant,
          primary == 'Export diagnostics' ? 'primary' : 'secondary',
        );
      }
      expect(
        button(tester, 'Close').variant,
        primary == 'Close' ? 'primary' : 'ghost',
      );
      if (code == StartupErrorCode.dataDirDenied ||
          code == StartupErrorCode.diskFull) {
        expect(find.text('test/data'), findsOneWidget);
      }
      if (code == StartupErrorCode.ledgerTooNew) {
        expect(find.textContaining('structure version 12'), findsOneWidget);
      }
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text(wire), findsOneWidget);
      expect(find.text('test error'), findsOneWidget);
      expect(find.text('0.1.0 (abc123) · Test OS'), findsOneWidget);
    });
  }

  testWidgets('Chinese failure page reports all four export states', (
    tester,
  ) async {
    final result = Completer<String>();
    var exports = 0;
    final opened = <Uri>[];
    await tester.pumpWidget(
      host(
        StartupFailurePage(
          card: card(
            StartupErrorCode.dataDirDenied,
            export: () => ++exports == 1 ? result.future : Future.error('拒绝访问'),
            openLink: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
        strings: chineseStrings,
      ),
    );
    expect(find.text('没有权限读写数据目录'), findsOneWidget);
    expect(find.textContaining('已保存到'), findsNothing);
    await tester.tap(find.text(chineseStrings.exportDiagnostics));
    await tester.pump();
    expect(button(tester, chineseStrings.exporting).onPressed, isNull);
    result.complete(_exportPath);
    await tester.pumpAndSettle();
    expect(find.text(chineseStrings.savedTo0(_exportPath)), findsOneWidget);
    await tester.tap(find.text(chineseStrings.openContainingFolder));
    expect(opened, [Uri.directory('downloads')]);
    await tester.tap(find.text(chineseStrings.exportDiagnostics));
    await tester.pumpAndSettle();
    expect(find.textContaining('拒绝访问'), findsOneWidget);
    expect(find.textContaining('把里面最近的日志'), findsOneWidget);
    expect(find.textContaining('已保存到'), findsNothing);
  });

  for (final enabled in [false, true]) {
    testWidgets(
      'failed stats shell exposes only usable navigation with news $enabled',
      (tester) async {
        tester.view.physicalSize = const Size(1180, 820);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          host(
            AppShell(
              failureCard: card(
                StartupErrorCode.ledgerCorrupt,
                full: false,
                newsEnabled: enabled,
              ),
              news: const Text('News content'),
              newsEnabled: enabled,
            ),
          ),
        );
        expect(find.text('The usage ledger is damaged'), findsOneWidget);
        expect(find.byType(LensCard), findsOneWidget);
        expect(find.text('Close'), findsNothing);
        expect(find.text('Statistics unavailable'), findsOneWidget);
        expect(
          find.text('AI news still works.'),
          enabled ? findsOneWidget : findsNothing,
        );
        expect(
          tester
              .getSemantics(find.byKey(const Key('nav-home')))
              .flagsCollection
              .isSelected
              .toBoolOrNull(),
          true,
        );
        final disabled = [
          'detail',
          'sessions',
          'sources',
          'settings',
          if (!enabled) 'news',
        ];
        for (final id in disabled) {
          final item = find.byKey(ValueKey('nav-$id'));
          expect(
            tester.getSemantics(item).flagsCollection.isEnabled.toBoolOrNull(),
            false,
          );
          expect(
            tester
                .widget<InkWell>(
                  find.descendant(of: item, matching: find.byType(InkWell)),
                )
                .canRequestFocus,
            false,
          );
          await tester.tap(item);
          expect(find.text('The usage ledger is damaged'), findsOneWidget);
        }
        for (var i = 0; i < 8; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final key = FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<StatsNavRow>()
              ?.key;
          expect(
            disabled.map((id) => ValueKey('nav-$id')),
            isNot(contains(key)),
          );
        }
        if (enabled) {
          await tester.tap(find.byKey(const Key('nav-news')));
          await tester.pumpAndSettle();
          expect(find.text('News content'), findsOneWidget);
          expect(find.text('The usage ledger is damaged'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
