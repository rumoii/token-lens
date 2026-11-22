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
import 'startup_failure.dart';
import 'startup_failure_page.dart';
import 'src/rust/api/news.dart' as native;
import 'src/rust/frb_generated.dart';
import 'src/rust/api/stats.dart' as stats;
import 'stats_controller.dart';
import 'stats_gateway.dart';
import 'stats/preferences.dart';
import 'stats/logic/pricing_update.dart';
import 'stats/mini/mini_window.dart';
import 'stats/theme/palette.dart';
import 'stats/widgets/primitives.dart';
import 'stats/widgets/interface_scale.dart';
import 'window_theme.dart';
import 'runtime_errors.dart';
import 'src/rust/api/diagnostics.dart' as diagnostics;

final _runtimeErrors = RuntimeErrors();

Future<bool> _openLink(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

void main(List<String> args) {
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
    const versionArg = '--token-lens-build-version=';
    final version = args.isNotEmpty && args.last.startsWith(versionArg)
        ? args.last.substring(versionArg.length)
        : null;
    runApp(
      TokenLensApp(
        executableVersion: version,
        miniPlatform: Platform.isWindows || Platform.isMacOS
            ? DesktopMiniWindowPlatform()
            : null,
      ),
    );
  }, _runtimeErrors.report);
}

class TokenLensApp extends StatefulWidget {
  const TokenLensApp({super.key, this.executableVersion, this.miniPlatform});

  final String? executableVersion;
  final MiniWindowPlatform? miniPlatform;

  @override
  State<TokenLensApp> createState() => _TokenLensAppState();
}

class _TokenLensAppState extends State<TokenLensApp>
    with WidgetsBindingObserver {
  late final AppLifecycleListener _lifecycle;
  NewsController? _controller;
  StatsController? _statsController;
  MiniWindow? _miniWindow;
  StartupFailure? _statsFailure;
  StartupFailure? _startupFailure;
  bool _previewDirectoriesMissing = false;
  bool _rustReady = false;
  bool _closing = false;
  String? _dataDir, _logDirectory, _buildInfo;
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
        if (mounted && !_closing) {
          setState(() => _previewDirectoriesMissing = true);
        }
        return;
      }
      _dataDir = override;
      try {
        await RustLib.init();
        _rustReady = true;
      } catch (error, stack) {
        try {
          _dataDir ??= await _defaultDataDir();
        } catch (_) {
          // The loader failure is the primary error.
        }
        await _showStartupFailure(
          StartupFailure(StartupErrorCode.appFilesMissing, error.toString()),
          error,
          stack,
        );
        return;
      }
      final dataDir = _dataDir ??= await _defaultDataDir();
      if (!mounted || _closing) return;
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
      final controller = NewsController(
        RustNewsGateway(client),
        enabled: preferences.newsEnabled,
      );
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
          news: controller,
          pricingRequest: override == null && logsHome == null
              ? requestPricing
              : null,
          systemLanguage: () => PlatformDispatcher.instance.locale.languageCode,
        );
      } catch (error, stack) {
        _runtimeErrors.report(error, stack);
        _statsFailure = parseStartupFailure(error);
        await _loadFailureDetails();
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
        final platform = widget.miniPlatform;
        if (statsController != null && platform != null) {
          _miniWindow = MiniWindow(
            controller: statsController,
            platform: platform,
          );
        }
      });
      if (statsController == null) unawaited(controller.start());
      statsController?.addListener(_statsChanged);
      if (statsController != null) unawaited(statsController.start());
    } catch (error, stack) {
      await _showStartupFailure(parseStartupFailure(error), error, stack);
    }
  }

  Future<String> _defaultDataDir() async =>
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}data';

  Future<void> _showStartupFailure(
    StartupFailure failure,
    Object error,
    StackTrace stack,
  ) async {
    _runtimeErrors.report(error, stack);
    await _loadFailureDetails();
    if (mounted && !_closing) setState(() => _startupFailure = failure);
  }

  Future<void> _loadFailureDetails() async {
    if (_rustReady) {
      try {
        _buildInfo = await diagnostics.startupBuildInfo();
      } catch (_) {
        // Build metadata is optional when the core cannot return it.
      }
    }
    if (_buildInfo == null) {
      var version = widget.executableVersion;
      if (version == null && Platform.isMacOS) {
        try {
          version = await const MethodChannel('token_lens/build')
              .invokeMethod<String>('version')
              .timeout(const Duration(milliseconds: 300));
        } catch (_) {
          // The system version still identifies the platform when metadata is unavailable.
        }
      }
      _buildInfo = '${version ?? '—'} · ${Platform.operatingSystemVersion}';
    }
    if (_dataDir case final dataDir?) {
      final logs = Directory('$dataDir${Platform.pathSeparator}logs');
      try {
        _logDirectory = await logs.exists()
            ? logs.path
            : await Directory(dataDir).exists()
            ? dataDir
            : null;
      } on FileSystemException {
        _logDirectory = null;
      }
    }
  }

  Future<String> _exportFailure(
    StartupFailure failure,
    AppStrings strings,
  ) async {
    Directory? downloads;
    try {
      downloads = await getDownloadsDirectory();
    } catch (_) {
      // The data directory is the fallback when Downloads is unavailable.
    }
    final dataDir = _dataDir;
    if (downloads == null &&
        (dataDir == null || !await Directory(dataDir).exists())) {
      throw StateError(strings.startupExportDestinationUnavailable);
    }
    return diagnostics.exportStartupDiagnostics(
      dataDir: dataDir,
      logsHome: Platform.environment['TOKEN_LENS_PREVIEW_HOME'],
      directory: downloads?.path ?? '$dataDir${Platform.pathSeparator}exports',
      errorCode: failure.code.wire,
      message: failure.message,
    );
  }

  void _close() =>
      ServicesBinding.instance.exitApplication(AppExitType.required);

  StartupFailureCard _failureCard(
    StartupFailure failure,
    AppStrings strings, {
    required bool full,
  }) => StartupFailureCard(
    failure: failure,
    dataDir: _dataDir,
    version: _buildInfo ?? '—',
    exportDiagnostics: _rustReady
        ? () => _exportFailure(failure, strings)
        : null,
    logDirectory: _logDirectory,
    appDirectory: File(Platform.resolvedExecutable).parent.path,
    openLink: _openLink,
    onClose: full ? _close : null,
    newsEnabled: !full && _preferences.newsEnabled,
  );

  Future<AppExitResponse> _exit() async {
    _closing = true;
    try {
      await _miniWindow?.saveBeforeClose().timeout(
        const Duration(milliseconds: 500),
      );
    } catch (_) {
      // Window placement is optional at shutdown.
    }
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
    _miniWindow?.dispose();
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
    final themeMode = switch (prefs.appearance) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    return WindowTheme(
      themeMode: themeMode,
      child: MaterialApp(
        title: 'Token Lens',
        builder: (_, child) => CallbackShortcuts(
          bindings: {
            if (widget.miniPlatform != null)
              SingleActivator(
                LogicalKeyboardKey.keyW,
                control: Platform.isWindows,
                meta: Platform.isMacOS,
                includeRepeats: false,
              ): () => unawaited(
                ServicesBinding.instance.exitApplication(
                  AppExitType.cancelable,
                ),
              ),
          },
          child: LensInterfaceScale(
            scale: _statsController?.miniMode == true ? 1 : prefs.uiScale,
            child: AppLanguageScope(strings: strings, child: child!),
          ),
        ),
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
        home: _startupFailure != null
            ? StartupFailurePage(
                card: _failureCard(_startupFailure!, strings, full: true),
              )
            : _controller != null
            ? AppShell(
                statsController: _statsController,
                miniWindow: _miniWindow,
                openLink: _openLink,
                failureCard: _statsFailure == null
                    ? null
                    : _failureCard(_statsFailure!, strings, full: false),
                news: NewsPage(controller: _controller!, openLink: _openLink),
                newsEnabled: prefs.newsEnabled,
                sidebarSpacing: prefs.spacing,
                newsListenable: _controller,
                newsUnread: () => _controller?.totalUnread ?? 0,
              )
            : Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: !_previewDirectoriesMissing
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
                                strings.debugRunsRequireTokenLensPreviewData,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 20),
                              LensButton(
                                onPressed: _close,
                                label: strings.close,
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
