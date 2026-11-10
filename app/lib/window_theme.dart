import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class WindowTheme extends StatefulWidget {
  const WindowTheme({super.key, required this.themeMode, required this.child});

  final ThemeMode themeMode;
  final Widget child;

  @override
  State<WindowTheme> createState() => _WindowThemeState();
}

class _WindowThemeState extends State<WindowTheme> with WidgetsBindingObserver {
  static const _channel = MethodChannel('token_lens/window');
  bool? _lastDark;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_sync());
  }

  @override
  void didUpdateWidget(WindowTheme oldWidget) {
    super.didUpdateWidget(oldWidget);
    unawaited(_sync());
  }

  @override
  void didChangePlatformBrightness() => unawaited(_sync());

  Future<void> _sync() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    final dark = switch (widget.themeMode) {
      ThemeMode.light => false,
      ThemeMode.dark => true,
      ThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark,
    };
    if (dark == _lastDark) return;
    _lastDark = dark;
    try {
      await _channel.invokeMethod<void>('setDarkTitleBar', dark);
    } on MissingPluginException {
      // Older runners may not provide the window channel.
    } on PlatformException {
      // A title-bar failure must not interrupt the app.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
