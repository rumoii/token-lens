import 'l10n/app_strings.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, AppExitType, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_shell.dart';
import 'news_controller.dart';
import 'news_page.dart';
import 'rust_gateway.dart';
import 'src/rust/api/news.dart' as native;
import 'src/rust/frb_generated.dart';
import 'src/rust/api/stats.dart' as stats;
import 'stats_controller.dart';
import 'stats_gateway.dart';
import 'stats/preferences.dart';
import 'stats/theme/palette.dart';
import 'window_theme.dart';
import 'runtime_errors.dart';
import 'src/rust/api/diagnostics.dart' as diagnostics;

final _runtimeErrors = RuntimeErrors();

Future<bool> _openLink(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      _runtimeErrors.report(
        details.exception,
        details.stack ?? StackTrace.current,
      );
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _runtimeErrors.report(error, stack);
      return true;
    };
    runApp(const TokenLensApp());
  }, _runtimeErrors.report);
}

class TokenLensApp extends StatefulWidget {
  const TokenLensApp({super.key});

  @override
  State<TokenLensApp> createState() => _TokenLensAppState();
}

enum _StartupFailure { previewDirectories, busy, initialization }

class _TokenLensAppState extends State<TokenLensApp>
    with WidgetsBindingObserver {
  late final AppLifecycleListener _lifecycle;
  NewsController? _controller;
  StatsController? _statsController;
  bool _statsInitializationFailed = false;
  _StartupFailure? _initializationError;
  bool _closing = false;
  String? _runtimeData;
  UiPreferences _preferences = const UiPreferences();
  void _statsChanged() {
    if (mounted && !_closing) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycle = AppLifecycleListener(onExitRequested: _exit);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final override = Platform.environment['TOKEN_LENS_PREVIEW_DATA_DIR'];
      final logsHome = Platform.environment['TOKEN_LENS_PREVIEW_HOME'];
      if (kDebugMode &&
          (override == null ||
              override.trim().isEmpty ||
              logsHome == null ||
              logsHome.trim().isEmpty)) {
        throw StateError('preview-directory-required');
      }
      final dataDir =
          override ??
          '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}data';
      await RustLib.init();
      _runtimeData = dataDir;
      _runtimeErrors.sink = (type, message, stack) =>
          diagnostics.writeRuntimeError(
            dataDir: dataDir,
            logsHome: logsHome,
            errorType: type,
            message: message,
            stack: stack,
          );
      await writeRuntimeEvent(
        () => diagnostics.runtimeStart(dataDir: dataDir, logsHome: logsHome),
      );
      final preferenceStore = PreferencesStore(Directory(dataDir));
      final preferences = await preferenceStore.read();
      if (!mounted || _closing) return;
      setState(() => _preferences = preferences);
      final client = await native.NewsClient.newInstance(dataDir: dataDir);
      final controller = NewsController(RustNewsGateway(client));
      StatsController? statsController;
      try {
        final statsClient = await stats.StatsClient.newInstance(
          dataDir: dataDir,
          logsHome: logsHome,
        );
        statsController = StatsController(
          RustStatsGateway(statsClient),
          store: preferenceStore,
          preferences: _preferences,
          systemLanguage: () => PlatformDispatcher.instance.locale.languageCode,
        );
      } catch (error, stack) {
        _runtimeErrors.report(error, stack);
        _statsInitializationFailed = true;
      }
      if (!mounted || _closing) {
        await statsController?.shutdown();
        statsController?.dispose();
        await controller.shutdown();
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _statsController = statsController;
      });
      unawaited(controller.start());
      statsController?.addListener(_statsChanged);
      if (statsController != null) unawaited(statsController.start());
    } catch (error, stack) {
      _runtimeErrors.report(error, stack);
      if (!mounted || _closing) return;
      final text = error.toString();
      setState(() {
        _initializationError = text.contains('preview-directory-required')
            ? _StartupFailure.previewDirectories
            : text.contains('busy:')
            ? _StartupFailure.busy
            : _StartupFailure.initialization;
      });
    }
  }

  Future<AppExitResponse> _exit() async {
    _closing = true;
    try {
      // The OS closes this process even if a disk operation cannot finish.
      await Future.wait([
        if (_controller != null) _controller!.shutdown(),
        if (_statsController != null) _statsController!.shutdown(),
      ]).timeout(const Duration(seconds: 3));
    } catch (_) {
      // Exit must remain available after partial initialization or I/O failure.
    }
    if (_runtimeData case final dataDir?) {
      try {
        await writeRuntimeEvent(
          () => diagnostics.runtimeExit(
            dataDir: dataDir,
            logsHome: Platform.environment['TOKEN_LENS_PREVIEW_HOME'],
          ),
        );
      } catch (_) {
        /* Exit remains available after an FFI failure. */
      }
    }
    return AppExitResponse.exit;
  }

  @override
  void didChangeLocales(List<Locale>? locales) => _statsChanged();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _closing = true;
    _lifecycle.dispose();
    _controller?.dispose();
    _statsController?.removeListener(_statsChanged);
    _statsController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _statsController?.preferences ?? _preferences;
    final strings = resolveStrings(
      prefs.language,
      PlatformDispatcher.instance.locale.languageCode,
    );
    final initializationError = switch (_initializationError) {
      _StartupFailure.previewDirectories =>
        strings.debugRunsRequireTokenLensPreviewData,
      _StartupFailure.busy => strings.tokenLensIsAlreadyUsingThisData,
      _StartupFailure.initialization => strings.cannotStartTokenLensCheckTheApp,
      null => null,
    };
    final themeMode = switch (prefs.appearance) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    return WindowTheme(
      themeMode: themeMode,
      child: MaterialApp(
        title: 'Token Lens',
        builder: (_, child) =>
            AppLanguageScope(strings: strings, child: child!),
        debugShowCheckedModeBanner: false,
        themeAnimationDuration:
            WidgetsBinding
                .instance
                .platformDispatcher
                .accessibilityFeatures
                .disableAnimations
            ? Duration.zero
            : kThemeAnimationDuration,
        theme: const LensPalette(false).theme,
        darkTheme: const LensPalette(true).theme,
        themeMode: themeMode,
        home: _controller != null
            ? AppShell(
                statsController: _statsController,
                openLink: _openLink,
                statsInitializationError: _statsInitializationFailed
                    ? strings.cannotOpenTheUsageLedgerCheckThat
                    : null,
                news: NewsPage(controller: _controller!, openLink: _openLink),
                newsListenable: _controller,
                newsUnread: () => _controller?.totalUnread ?? 0,
              )
            : Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: _initializationError == null
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 20),
                              Text(strings.openingTheLocalNewsCache),
                            ],
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.info_outline, size: 32),
                              const SizedBox(height: 16),
                              Text(
                                initializationError!,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 20),
                              OutlinedButton(
                                onPressed: () => ServicesBinding.instance
                                    .exitApplication(AppExitType.required),
                                child: Text(strings.close),
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
