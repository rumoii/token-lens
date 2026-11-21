import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../../stats_controller.dart';

class MiniDisplay {
  const MiniDisplay(this.workArea, [this.scale = 1]);
  final Rect workArea;
  final double scale;
}

abstract interface class MiniWindowPlatform {
  Future<Rect> getBounds();
  Future<List<MiniDisplay>> workAreas();
  Future<bool> isMaximized();
  Future<void> setMaximized(bool value);
  Future<void> setCompact(bool value, {required bool rounded});
  Future<void> setPinned(bool value);
  Future<void> setLimits(Size min, Size? max);
  Future<void> setBounds(Rect value);
  Future<void> startDragging();
  void observeBounds(VoidCallback? callback, {ValueChanged<Size?>? onResize});
}

class DesktopMiniWindowPlatform
    with WindowListener
    implements MiniWindowPlatform {
  static const _channel = MethodChannel('token_lens/window');
  Future<void>? _initializing;
  VoidCallback? _onBoundsChanged;
  ValueChanged<Size?>? _onResize;
  int _resizeTicket = 0;

  Future<void> _ready() => _initializing ??= windowManager.ensureInitialized();

  List<double> _coordinates(Object? value) =>
      (value as List).map((n) => (n as num).toDouble()).toList();

  @override
  Future<Rect> getBounds() async {
    await _ready();
    if (!Platform.isWindows) return windowManager.getBounds();
    final b = _coordinates(await _channel.invokeMethod('getFrame'));
    return Rect.fromLTWH(b[0], b[1], b[2], b[3]);
  }

  @override
  Future<List<MiniDisplay>> workAreas() async {
    final displays =
        await _channel.invokeListMethod<Object?>('workAreas') ?? [];
    return displays.map((display) {
      final b = _coordinates(display);
      return MiniDisplay(Rect.fromLTWH(b[0], b[1], b[2], b[3]), b[4]);
    }).toList();
  }

  @override
  Future<bool> isMaximized() async {
    await _ready();
    return windowManager.isMaximized();
  }

  @override
  Future<void> setMaximized(bool value) =>
      value ? windowManager.maximize() : windowManager.unmaximize();

  @override
  Future<void> setCompact(bool value, {required bool rounded}) async {
    if (Platform.isWindows) {
      await _channel.invokeMethod<void>('setMiniFrame', [value, rounded]);
    } else {
      await windowManager.setTitleBarStyle(
        value ? TitleBarStyle.hidden : TitleBarStyle.normal,
        windowButtonVisibility: !value,
      );
      await _channel.invokeMethod<void>('setMiniFrame', value);
    }
    await windowManager.setMaximizable(!value);
  }

  @override
  Future<void> setPinned(bool value) => windowManager.setAlwaysOnTop(value);

  @override
  Future<void> setLimits(Size min, Size? max) async {
    await windowManager.setMinimumSize(min);
    await windowManager.setMaximumSize(
      max ??
          (Platform.isMacOS
              ? const Size(1000000, 1000000)
              : const Size(-1, -1)),
    );
  }

  @override
  Future<void> setBounds(Rect b) => Platform.isWindows
      ? _channel.invokeMethod<void>('setFrame', [
          b.left,
          b.top,
          b.width,
          b.height,
        ])
      : windowManager.setBounds(b);

  @override
  Future<void> startDragging() => windowManager.startDragging();

  @override
  void observeBounds(VoidCallback? callback, {ValueChanged<Size?>? onResize}) {
    windowManager.removeListener(this);
    _resizeTicket++;
    _onBoundsChanged = callback;
    _onResize = onResize;
    if (callback != null) windowManager.addListener(this);
  }

  Future<void> _reportResize() async {
    final ticket = ++_resizeTicket;
    try {
      Size? size;
      if (Platform.isWindows) {
        size = (await getBounds()).size;
      } else {
        // AppKit also emits resize for programmatic window changes.
        final frame = await _channel.invokeListMethod<num>('liveFrameSize');
        if (frame != null) {
          size = Size(frame[0].toDouble(), frame[1].toDouble());
        }
      }
      if (ticket == _resizeTicket) _onResize?.call(size);
    } on PlatformException catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    }
  }

  @override
  void onWindowMove() => _onBoundsChanged?.call();
  @override
  void onWindowResize() {
    _onBoundsChanged?.call();
    if (_onResize != null) unawaited(_reportResize());
  }

  @override
  void onWindowMoved() => _onBoundsChanged?.call();
  @override
  void onWindowResized() {
    _resizeTicket++;
    _onResize?.call(null);
    _onBoundsChanged?.call();
  }
}

class MiniWindow {
  MiniWindow({required this.controller, required this.platform});

  static const fullMin = Size(700, 500);
  static const min = Size(296, 480);
  static const max = Size(480, 900);
  static const initial = Size(304, 620);

  final StatsController controller;
  final MiniWindowPlatform platform;
  ({Rect bounds, bool maximized})? _full;
  Future<void>? _transition;
  Timer? _saveTimer;
  final _liveSize = ValueNotifier<Size?>(null);
  ValueListenable<Size?> get sizeWhileResizing => _liveSize;
  bool _disposed = false;
  bool get switching => _transition != null;

  Future<void> enter() => _run(_enter);
  Future<void> exit() => _run(_exit);

  Future<void> _run(Future<void> Function() apply) {
    if (_disposed) return Future.value();
    return _transition ??= apply().whenComplete(() => _transition = null);
  }

  Future<void> _enter() async {
    if (_full != null) return;
    final saved = controller.preferences.mini;
    final bounds = _place(saved.bounds, await platform.workAreas());
    final maximized = await platform.isMaximized();
    if (maximized) await platform.setMaximized(false);
    final full = (bounds: await platform.getBounds(), maximized: maximized);
    try {
      await platform.setCompact(true, rounded: true);
      await platform.setLimits(min, max);
      await platform.setBounds(bounds);
      await platform.setPinned(saved.pinned);
    } catch (_) {
      await _restore(full);
      rethrow;
    }
    if (_disposed) return;
    _full = full;
    unawaited(controller.setMiniMode(true));
    platform.observeBounds(
      _boundsChanged,
      onResize: (size) => _liveSize.value = size,
    );
  }

  Future<void> _exit() async {
    final full = _full;
    if (full == null) return;
    _saveTimer?.cancel();
    await _saveBounds();
    await _restore(full);
    _full = null;
    platform.observeBounds(null);
    _liveSize.value = null;
    unawaited(controller.setMiniMode(false));
  }

  Future<void> _restore(({Rect bounds, bool maximized}) full) async {
    await platform.setPinned(false);
    await platform.setLimits(fullMin, null);
    await platform.setCompact(false, rounded: false);
    await platform.setBounds(full.bounds);
    if (full.maximized) await platform.setMaximized(true);
  }

  Rect _place(Rect? saved, List<MiniDisplay> displays) {
    final w = (saved?.width ?? initial.width).clamp(min.width, max.width);
    final h = (saved?.height ?? initial.height).clamp(min.height, max.height);
    for (final display in displays) {
      if (saved == null) break;
      final area = display.workArea;
      final scale = display.scale;
      final title = Rect.fromLTWH(saved.left, saved.top, w * scale, 36 * scale);
      final visible = area.intersect(title);
      if (visible.width >= 72 * scale && visible.height >= 18 * scale) {
        return Rect.fromLTWH(
          saved.left.clamp(
            area.left,
            (area.right - w * scale).clamp(area.left, area.right),
          ),
          saved.top.clamp(
            area.top,
            (area.bottom - h * scale).clamp(area.top, area.bottom),
          ),
          w,
          h,
        );
      }
    }
    final primary = displays.firstOrNull;
    if (primary == null) return Rect.fromLTWH(16, 16, w, h);
    final area = primary.workArea, scale = primary.scale;
    return Rect.fromLTWH(
      (area.right - (w + 16) * scale).clamp(area.left, area.right),
      area.top + 16 * scale,
      w,
      h,
    );
  }

  Future<void> togglePin() => _run(() async {
    final value = !controller.preferences.mini.pinned;
    await platform.setPinned(value);
    final prefs = controller.preferences;
    await controller.setPreferences(
      prefs.copyWith(mini: prefs.mini.copyWith(pinned: value)),
    );
  });

  Future<void> startDragging() => platform.startDragging();

  void _boundsChanged() {
    if (_disposed || switching || _full == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), () {
      if (_disposed || switching || _full == null) return;
      unawaited(
        _saveBounds().catchError((Object error, StackTrace stack) {
          FlutterError.reportError(
            FlutterErrorDetails(exception: error, stack: stack),
          );
        }),
      );
    });
  }

  Future<void> _saveBounds() async {
    final bounds = await platform.getBounds();
    if (_disposed || _full == null) return;
    final prefs = controller.preferences;
    if (bounds == prefs.mini.bounds) return;
    await controller.setPreferences(
      prefs.copyWith(mini: prefs.mini.copyWith(bounds: bounds)),
    );
  }

  Future<void> saveBeforeClose() async {
    _saveTimer?.cancel();
    await _transition;
    if (_full != null) await _saveBounds();
  }

  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    platform.observeBounds(null);
    _liveSize.dispose();
  }
}
