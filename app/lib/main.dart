import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'news_controller.dart';
import 'news_page.dart';
import 'rust_gateway.dart';
import 'src/rust/api/news.dart' as native;
import 'src/rust/frb_generated.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TokenLensApp());
}

class TokenLensApp extends StatefulWidget {
  const TokenLensApp({super.key});

  @override
  State<TokenLensApp> createState() => _TokenLensAppState();
}

class _TokenLensAppState extends State<TokenLensApp> {
  late final AppLifecycleListener _lifecycle;
  NewsController? _controller;
  String? _initializationError;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _exit);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final override = Platform.environment['TOKEN_LENS_PREVIEW_DATA_DIR'];
      if (kDebugMode && (override == null || override.trim().isEmpty)) {
        throw StateError('preview-directory-required');
      }
      final dataDir =
          override ??
          '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}news-preview';
      await RustLib.init();
      final client = await native.NewsClient.newInstance(dataDir: dataDir);
      final controller = NewsController(RustNewsGateway(client));
      if (!mounted || _closing) {
        await controller.shutdown();
        controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (error) {
      if (!mounted || _closing) return;
      final text = error.toString();
      setState(() {
        _initializationError = text.contains('preview-directory-required')
            ? '开发预览需要设置 TOKEN_LENS_PREVIEW_DATA_DIR 为独立的绝对目录。'
            : text.contains('busy:')
            ? '预览已在运行，当前数据目录正在使用。请回到已打开的窗口。'
            : '无法打开新闻预览。请检查应用文件是否完整，以及预览目录是否可读写。';
      });
    }
  }

  Future<AppExitResponse> _exit() async {
    _closing = true;
    try {
      // The OS closes this process even if a disk operation cannot finish.
      await _controller?.shutdown().timeout(const Duration(seconds: 3));
    } catch (_) {
      // Exit must remain available after partial initialization or I/O failure.
    }
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _closing = true;
    _lifecycle.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Token Lens · Preview',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffa74b2d)),
      fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
    ),
    darkTheme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xffd97757),
        brightness: Brightness.dark,
      ),
      fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
    ),
    home: _controller != null
        ? NewsPage(
            controller: _controller!,
            openLink: (uri) =>
                launchUrl(uri, mode: LaunchMode.externalApplication),
          )
        : Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: _initializationError == null
                    ? const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 20),
                          Text('正在打开本地新闻缓存…'),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.info_outline, size: 32),
                          const SizedBox(height: 16),
                          Text(
                            _initializationError!,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 20),
                          OutlinedButton(
                            onPressed: () => ServicesBinding.instance
                                .exitApplication(AppExitType.required),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
              ),
            ),
          ),
  );
}
