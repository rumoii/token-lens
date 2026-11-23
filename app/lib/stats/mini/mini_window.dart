import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../../stats_controller.dart';
import '../preferences.dart';
import '../theme/palette.dart';

class MiniDisplay {
  const MiniDisplay(this.workArea, [this.scale = 1, Rect? bounds])
    : bounds = bounds ?? workArea;
  final Rect workArea;
  final Rect bounds;
  final double scale;
}

typedef MiniFrame = ({Rect bounds, double scale});
typedef MiniPillState = ({MiniPillEdge? edge, bool revealed});

abstract interface class MiniWindowPlatform {
  String? get pendingMethod;
  Future<Rect> getBounds();
  Future<MiniFrame> getFrame();
  Future<List<MiniDisplay>> workAreas();
  Future<bool> isMaximized();
  Future<void> setMaximized(bool value);
  Future<void> setCompact(bool value, {required bool rounded});
  Future<void> setPinned(bool value);
  Future<void> setLimits(Size min, Size? max);
  Future<void> setBounds(Rect value);
  bool get supportsPillTuck;
  Future<void> setPillFrame(bool value);
  Future<void> setPillTooltip(String? text);
  Future<void> setPillBounds(Rect value, MiniDisplay display);
  Future<bool> isPrimaryButtonDown();
  Future<bool> dragPill({Color? edgeAccent, bool requirePressed = false});
  Future<void> startDragging();
  void observeBounds(VoidCallback? callback, {ValueChanged<Size?>? onResize});
}

class DesktopMiniWindowPlatform
    with WindowListener
    implements MiniWindowPlatform {
  static const _channel = MethodChannel('token_lens/window');
  static const _managerChannel = MethodChannel('window_manager');
  final _pendingMethods = <Object, String>{};
  Future<void>? _initializing;
  VoidCallback? _onBoundsChanged;
  ValueChanged<Size?>? _onResize;
  int _resizeTicket = 0;

  @override
  String? get pendingMethod => _pendingMethods.values.lastOrNull;

  Future<T> _track<T>(String name, Future<T> Function() call) async {
    final token = Object();
    _pendingMethods[token] = name;
    try {
      return await call();
    } finally {
      _pendingMethods.remove(token);
    }
  }

  Future<T?> _invoke<T>(String name, [Object? arguments]) =>
      _track(name, () => _channel.invokeMethod<T>(name, arguments));

  Future<List<T>?> _invokeList<T>(String name) =>
      _track(name, () => _channel.invokeListMethod<T>(name));

  Future<void> _ready() => _initializing ??= _track(
    'ensureInitialized',
    windowManager.ensureInitialized,
  );

  List<double> _coordinates(Object? value) =>
      (value as List).map((n) => (n as num).toDouble()).toList();

  @override
  Future<Rect> getBounds() async => (await getFrame()).bounds;

  @override
  Future<MiniFrame> getFrame() async {
    await _ready();
    if (!Platform.isWindows) {
      return (
        bounds: await _track('getBounds', windowManager.getBounds),
        scale: 1.0,
      );
    }
    final b = _coordinates(await _invoke<Object?>('getFrame'));
    return (bounds: Rect.fromLTWH(b[0], b[1], b[2], b[3]), scale: b[4]);
  }

  @override
  Future<List<MiniDisplay>> workAreas() async {
    final displays = await _invokeList<Object?>('workAreas') ?? [];
    return displays.map((display) {
      final b = _coordinates(display);
      return MiniDisplay(
        Rect.fromLTWH(b[0], b[1], b[2], b[3]),
        b[4],
        Rect.fromLTWH(b[5], b[6], b[7], b[8]),
      );
    }).toList();
  }

  @override
  Future<bool> isMaximized() async {
    await _ready();
    return _track('isMaximized', windowManager.isMaximized);
  }

  @override
  Future<void> setMaximized(bool value) => value
      ? _track('maximize', windowManager.maximize)
      : _track('unmaximize', windowManager.unmaximize);

  @override
  Future<void> setCompact(bool value, {required bool rounded}) async {
    if (Platform.isWindows) {
      await _invoke<void>('setMiniFrame', [value, rounded]);
    } else {
      await _track(
        'setTitleBarStyle',
        () => windowManager.setTitleBarStyle(
          value ? TitleBarStyle.hidden : TitleBarStyle.normal,
          windowButtonVisibility: !value,
        ),
      );
      await _invoke<void>('setMiniFrame', value);
    }
    await _track('setMaximizable', () => windowManager.setMaximizable(!value));
  }

  @override
  Future<void> setPinned(bool value) =>
      _track('setAlwaysOnTop', () => windowManager.setAlwaysOnTop(value));

  @override
  Future<void> setLimits(Size min, Size? max) async {
    await _track('setMinimumSize', () => windowManager.setMinimumSize(min));
    await _track(
      'setMaximumSize',
      () => windowManager.setMaximumSize(
        max ??
            (Platform.isMacOS
                ? const Size(1000000, 1000000)
                : const Size(-1, -1)),
      ),
    );
  }

  @override
  Future<void> setBounds(Rect b) => Platform.isWindows
      ? _invoke<void>('setFrame', [b.left, b.top, b.width, b.height])
      : _track('setBounds', () => windowManager.setBounds(b));

  @override
  Future<void> startDragging() => windowManager.startDragging();

  @override
  bool get supportsPillTuck => Platform.isWindows;

  @override
  Future<void> setPillFrame(bool value) async {
    await _track('setResizable', () => windowManager.setResizable(!value));
    await _invoke<void>('setPillFrame', value);
  }

  @override
  Future<void> setPillTooltip(String? text) =>
      _invoke<void>('setPillTooltip', text);

  @override
  Future<void> setPillBounds(Rect b, MiniDisplay display) => Platform.isWindows
      ? _invoke<void>('setFrame', [
          b.left,
          b.top,
          b.width,
          b.height,
          display.scale,
        ])
      : setBounds(b);

  @override
  Future<bool> isPrimaryButtonDown() async =>
      await _invoke<bool>('isPrimaryButtonDown') ?? false;

  @override
  Future<bool> dragPill({
    Color? edgeAccent,
    bool requirePressed = false,
  }) async {
    if (!Platform.isWindows) {
      return await _invoke<bool>('dragPill') ?? false;
    }
    Future<bool> start() async {
      if (requirePressed) {
        return await _invoke<bool>('dragPressedPill') ?? false;
      }
      // Match window_manager's full-screen guard while tracking both calls.
      if (await _track('isFullScreen', windowManager.isFullScreen)) {
        return false;
      }
      await _track(
        'startDragging',
        () => _managerChannel.invokeMethod<void>('startDragging'),
      );
      return true;
    }

    final rgb = edgeAccent?.toARGB32();
    if (rgb == null) return start();
    await _invoke<void>('setPillDragAccent', rgb & 0xffffff);
    try {
      return await start();
    } finally {
      await _invoke<void>('setPillDragAccent');
    }
  }

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
        final frame = await _invokeList<num>('liveFrameSize');
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

enum _MiniAction {
  enter,
  restorePill,
  exit,
  enterPill,
  expandPill,
  startPillDragging,
  resizePill,
  togglePin,
}

class _MiniTransition {
  _MiniTransition(this.id, this.action, this.apply);

  final int id;
  final _MiniAction action;
  Future<void> Function() apply;
  final completion = Completer<void>();
  int merged = 0;
}

class MiniWindow {
  MiniWindow({required this.controller, required this.platform, this._log});

  static const fullMin = Size(700, 500);
  static const min = Size(296, 480);
  static const max = Size(480, 900);
  static const initial = Size(304, 620);
  static const pillHeight = 36.0;
  static const pillMaxWidth = 240.0;
  static const pillTab = 26.0;
  static const _pillDefaultWidth = 148.0;
  static const _pillSnap = 24.0;
  static const _pillHideDelay = Duration(milliseconds: 400);

  final StatsController controller;
  final MiniWindowPlatform platform;
  final void Function(String level, String message)? _log;
  ({Rect bounds, bool maximized})? _full;
  Future<void>? _transition;
  final _userQueue = Queue<_MiniTransition>();
  _MiniTransition? _pendingResize;
  _MiniTransition? _activeTransition;
  Timer? _transitionWarning;
  int _nextTransitionId = 0;
  Timer? _saveTimer;
  final _liveSize = ValueNotifier<Size?>(null);
  ValueListenable<Size?> get sizeWhileResizing => _liveSize;
  final _pillState = ValueNotifier<MiniPillState?>(null);
  ValueListenable<MiniPillState?> get pillState => _pillState;
  double get pillWidth => _pillAnchor.width;
  // The anchor is the fully visible position, even when only the tab is shown.
  Rect _pillAnchor = Rect.zero;
  Rect _pillFrame = Rect.zero;
  MiniDisplay? _pillDisplay;
  Timer? _pillHideTimer;
  Ticker? _pillSlide;
  Future<void>? _pillSlideWrite;
  bool _disposed = false;
  bool _closing = false;
  bool get switching => _transition != null;

  void _emit(String level, String message) {
    try {
      _log?.call(level, message);
    } catch (_) {
      // A failed diagnostic must not interrupt window operations.
    }
  }

  void reportStalePress(int oldPointer, int newPointer) =>
      _emit('INFO', 'stale press replaced old=$oldPointer new=$newPointer');

  String _transitionLabel(_MiniTransition next) =>
      'action=${next.action.name} id=${next.id}';

  void _discard(_MiniTransition next, String reason) =>
      _emit('INFO', 'discard ${_transitionLabel(next)} reason=$reason');

  Future<void> enter() => _run(_MiniAction.enter, _enter);
  Future<void> restorePill() => controller.preferences.mini.pill
      ? _run(_MiniAction.restorePill, () => _enter(restorePill: true))
      : Future.value();
  Future<void> exit() => _run(_MiniAction.exit, _exit);

  Future<void> _run(_MiniAction action, Future<void> Function() apply) {
    if (_disposed || _closing) return Future.value();
    final resizing = action == _MiniAction.resizePill;
    final previous = resizing ? _pendingResize : _userQueue.lastOrNull;
    if (previous != null &&
        previous.action == action &&
        action != _MiniAction.togglePin) {
      if (resizing) previous.apply = apply;
      previous.merged++;
      return previous.completion.future;
    }
    final next = _MiniTransition(++_nextTransitionId, action, apply);
    if (switching) _emit('INFO', 'queued ${_transitionLabel(next)}');
    if (resizing) {
      _pendingResize = next;
    } else {
      _userQueue.addLast(next);
    }
    _transition ??= Future<void>.microtask(_drainTransitions);
    return next.completion.future;
  }

  Future<void> _drainTransitions() async {
    try {
      while (!_disposed) {
        final _MiniTransition? next;
        if (_userQueue.isNotEmpty) {
          next = _userQueue.removeFirst();
        } else {
          next = _pendingResize;
          _pendingResize = null;
        }
        if (next == null) break;
        final failure = await _executeTransition(next);
        if (failure == null) {
          next.completion.complete();
        } else {
          next.completion.completeError(failure.error, failure.stack);
        }
      }
    } finally {
      _transition = null;
    }
  }

  Future<({Object error, StackTrace stack})?> _executeTransition(
    _MiniTransition next,
  ) async {
    _activeTransition = next;
    final label = _transitionLabel(next);
    final elapsed = Stopwatch()..start();
    _emit('INFO', 'start $label');
    if (_log != null) {
      _transitionWarning = Timer(const Duration(seconds: 5), () {
        final method = platform.pendingMethod ?? 'none';
        _emit(
          'WARN',
          'waiting $label elapsedMs=${elapsed.elapsedMilliseconds} platformMethod=$method',
        );
      });
    }
    Object? failure;
    try {
      await next.apply();
      return null;
    } catch (error, stack) {
      failure = error;
      return (error: error, stack: stack);
    } finally {
      _transitionWarning?.cancel();
      _transitionWarning = null;
      _activeTransition = null;
      final merged = next.merged == 0 ? '' : ' merged=${next.merged}';
      final outcome = failure == null
          ? 'ok'
          : 'error errorType=${failure.runtimeType}';
      _emit(
        'INFO',
        'end $label elapsedMs=${elapsed.elapsedMilliseconds} result=$outcome$merged',
      );
    }
  }

  Future<void> _enter({bool restorePill = false}) async {
    if (_full != null) return;
    final saved = controller.preferences.mini;
    final displays = await platform.workAreas();
    final bounds = _place(saved.bounds, displays);
    final maximized = await platform.isMaximized();
    if (maximized) await platform.setMaximized(false);
    final full = (bounds: await platform.getBounds(), maximized: maximized);
    try {
      await platform.setCompact(true, rounded: true);
      if (restorePill) {
        final replay = _resolvePillPlacement(
          saved.pillBounds,
          saved.pillEdge,
          displays,
        );
        unawaited(controller.setMiniMode(true));
        await _applyPill(replay.anchor, replay.display, replay.edge);
      } else {
        await platform.setLimits(min, max);
        await platform.setBounds(bounds);
        await platform.setPinned(saved.pinned);
      }
    } catch (_) {
      await _restore(full);
      if (restorePill) unawaited(controller.setMiniMode(false));
      rethrow;
    }
    if (_disposed) return;
    _full = full;
    unawaited(controller.setMiniMode(true));
    platform.observeBounds(
      _boundsChanged,
      onResize: (size) {
        if (_pillState.value == null) _liveSize.value = size;
      },
    );
    if (restorePill) await _savePill(bounds: bounds);
  }

  Future<void> _exit() async {
    final full = _full;
    if (full == null || _pillState.value != null) return;
    _saveTimer?.cancel();
    await _saveBounds();
    await _restore(full);
    _full = null;
    platform.observeBounds(null);
    _liveSize.value = null;
    unawaited(controller.setMiniMode(false));
  }

  Future<void> _restore(({Rect bounds, bool maximized}) full) async {
    if (_pillDisplay != null) {
      await platform.setPillFrame(false);
    }
    await platform.setPinned(false);
    await platform.setLimits(fullMin, null);
    await platform.setCompact(false, rounded: false);
    await platform.setBounds(full.bounds);
    if (full.maximized) await platform.setMaximized(true);
    if (_pillDisplay != null) {
      _pillDisplay = null;
      if (!_disposed) _pillState.value = null;
    }
  }

  Future<void> enterPill(double width) => _run(_MiniAction.enterPill, () async {
    if (_full == null || _pillState.value != null) return;
    _saveTimer?.cancel();
    _liveSize.value = null;
    final frame = await platform.getFrame();
    final display = _displayFor(frame, await platform.workAreas());
    final b = frame.bounds;
    final size = _pillSize(width, display);
    // Frame origins are in screen pixels on Windows. Rect.width is in DIPs.
    final aligned = _clampPill(
      Offset(
        b.left + b.width * frame.scale - size.width * display.scale,
        b.top,
      ),
      size,
      display,
    );
    try {
      await _applyPill(aligned, display, null);
    } catch (_) {
      await platform.setPillFrame(false);
      await platform.setLimits(min, max);
      await platform.setBounds(b);
      await platform.setPinned(controller.preferences.mini.pinned);
      _pillDisplay = null;
      if (!_disposed) _pillState.value = null;
      rethrow;
    }
    await _savePill(bounds: b);
  });

  Future<void> _applyPill(
    Rect anchor,
    MiniDisplay display,
    MiniPillEdge? edge,
  ) async {
    _pillDisplay = display;
    await platform.setLimits(Size.zero, null);
    await platform.setPillFrame(true);
    await _placePill(anchor, display, edge);
    await platform.setPinned(true);
  }

  Future<void> _placePill(
    Rect anchor,
    MiniDisplay display,
    MiniPillEdge? edge,
  ) async {
    final frame = _tuckedFrame(anchor, display, edge);
    if (_disposed) return;
    _pillAnchor = anchor;
    _pillFrame = frame;
    _pillDisplay = display;
    _pillState.value = (edge: edge, revealed: false);
    await platform.setPillBounds(frame, display);
  }

  Future<void> expandPill() => _run(_MiniAction.expandPill, () async {
    final state = _pillState.value;
    final previousDisplay = _pillDisplay;
    if (state == null || previousDisplay == null) return;
    await _stopPillMotion();
    final prefs = controller.preferences;
    final compact = prefs.mini.bounds?.size ?? initial;
    final (:anchor, :display, :edge) = _resolvePillPlacement(
      _pillAnchor,
      state.edge,
      await platform.workAreas(),
    );
    final scale = display.scale;
    final right = _alignRight(anchor, display, edge);
    final size = _fitWorkArea(
      Size(
        compact.width.clamp(min.width, max.width),
        compact.height.clamp(min.height, max.height),
      ),
      display,
    );
    final bounds = _clampPill(
      anchor.topLeft +
          Offset(right ? (anchor.width - size.width) * scale : 0, 0),
      size,
      display,
    );
    try {
      await platform.setPillFrame(false);
      await platform.setLimits(_fitWorkArea(min, display), max);
      await platform.setBounds(bounds);
      await platform.setPinned(prefs.mini.pinned);
    } catch (_) {
      await _applyPill(_pillAnchor, previousDisplay, state.edge);
      rethrow;
    }
    if (_disposed) return;
    _pillDisplay = null;
    _pillState.value = null;
    final current = controller.preferences;
    await controller.setPreferences(
      current.copyWith(
        mini: current.mini.copyWith(bounds: bounds, pill: false),
      ),
    );
  });

  Future<void> startPillDragging({Color? edgeAccent}) {
    final queued = switching;
    return _run(
      _MiniAction.startPillDragging,
      () => _dragPill(edgeAccent, queued),
    );
  }

  Future<void> _dragPill(Color? edgeAccent, bool queued) async {
    final state = _pillState.value;
    final from = _pillDisplay;
    if (state == null || from == null) return;
    if (queued && !await platform.isPrimaryButtonDown()) {
      _discard(_activeTransition!, 'primary_button_released');
      return;
    }
    if (_disposed) return;
    final before = _pillAnchor;
    await _stopPillMotion();
    if (_disposed) return;
    final previousFrame = _pillFrame;
    try {
      if (state.edge != null) {
        await platform.setPillBounds(_pillAnchor, from);
        if (!_disposed) _pillState.value = (edge: null, revealed: false);
      }
      final started = await platform.dragPill(
        edgeAccent: edgeAccent,
        requirePressed: queued,
      );
      if (_disposed) return;
      if (!started) {
        _discard(
          _activeTransition!,
          queued ? 'native_drag_guard' : 'native_drag_unavailable',
        );
        if (state.edge != null) {
          await platform.setPillBounds(previousFrame, from);
          if (!_disposed) _pillState.value = state;
        }
        return;
      }
      final frame = await platform.getFrame();
      final displays = await platform.workAreas();
      final display = _displayFor(frame, displays);
      final edge = platform.supportsPillTuck ? _snapEdge(frame, display) : null;
      final area = display.workArea;
      final size = _pillSize(_pillAnchor.width, display);
      final x = switch (edge) {
        MiniPillEdge.left => area.left,
        MiniPillEdge.right => area.right - size.width * display.scale,
        null => frame.bounds.left,
      };
      final anchor = _clampPill(Offset(x, frame.bounds.top), size, display);
      await _placePill(
        anchor,
        display,
        _exteriorEdge(anchor, display, edge, displays),
      );
    } catch (_) {
      await _placePill(before, from, state.edge);
      rethrow;
    }
    await _savePill();
  }

  Future<void> resizePill(double width) =>
      _run(_MiniAction.resizePill, () async {
        final display = _pillDisplay;
        final state = _pillState.value;
        if (display == null || state == null || (width - pillWidth).abs() < 1) {
          return;
        }
        final size = _pillSize(width, display);
        if (size == _pillAnchor.size) return;
        _cancelPillSlide();
        await _pillSlideWrite;
        if (_disposed) return;
        final right = _alignRight(_pillAnchor, display, state.edge);
        final x =
            _pillAnchor.left +
            (right ? (pillWidth - size.width) * display.scale : 0);
        final anchor = _clampPill(Offset(x, _pillAnchor.top), size, display);
        final edge = state.edge == null
            ? null
            : _exteriorEdge(
                anchor,
                display,
                state.edge,
                await platform.workAreas(),
              );
        final frame = state.revealed
            ? anchor
            : _tuckedFrame(anchor, display, edge);
        await platform.setPillBounds(frame, display);
        _pillAnchor = anchor;
        _pillFrame = frame;
        if (edge != state.edge) {
          _pillHideTimer?.cancel();
          _pillState.value = (edge: edge, revealed: false);
        }
        await _savePill();
      });

  void setPillHovered(bool value, {required bool reduceMotion}) {
    if (_disposed || _closing || _pillState.value?.edge == null || switching) {
      return;
    }
    _pillHideTimer?.cancel();
    if (value) {
      unawaited(_slidePill(true, reduceMotion));
    } else {
      _pillHideTimer = Timer(
        _pillHideDelay,
        () => unawaited(_slidePill(false, reduceMotion)),
      );
    }
  }

  Future<void> _slidePill(bool reveal, bool reduceMotion) async {
    final edge = _pillState.value?.edge;
    final display = _pillDisplay;
    if (_disposed ||
        switching ||
        edge == null ||
        display == null ||
        _pillState.value?.revealed == reveal) {
      return;
    }
    final state = (edge: edge, revealed: reveal);
    _pillState.value = state;
    _cancelPillSlide();
    if (_pillSlideWrite case final write?) await write;
    if (_disposed || switching || _pillState.value != state) return;
    _cancelPillSlide();
    final from = _pillFrame;
    final to = reveal ? _pillAnchor : _tuckedFrame(_pillAnchor, display, edge);
    if (reduceMotion) {
      _writeSlideFrame(to, display);
      return;
    }
    _pillSlide = Ticker((elapsed) {
      if (_pillSlideWrite != null) return;
      final t = (elapsed.inMicroseconds / LensTokens.normal.inMicroseconds)
          .clamp(0.0, 1.0);
      final frame = Rect.lerp(from, to, LensTokens.ease.transform(t))!;
      _writeSlideFrame(frame, display);
      if (t == 1) _cancelPillSlide();
    })..start();
  }

  void _writeSlideFrame(Rect frame, MiniDisplay display) {
    if (_disposed || switching) return;
    _pillSlideWrite = platform
        .setPillBounds(frame, display)
        .then<void>(
          (_) => _pillFrame = frame,
          onError: (Object error, StackTrace stack) {
            FlutterError.reportError(
              FlutterErrorDetails(exception: error, stack: stack),
            );
          },
        )
        .whenComplete(() => _pillSlideWrite = null);
  }

  void _cancelPillSlide() {
    _pillSlide?.dispose();
    _pillSlide = null;
  }

  Future<void> _stopPillMotion() async {
    _pillHideTimer?.cancel();
    _cancelPillSlide();
    await _pillSlideWrite;
  }

  Future<void> _savePill({Rect? bounds}) async {
    if (_disposed) return;
    final prefs = controller.preferences;
    await controller.setPreferences(
      prefs.copyWith(
        mini: prefs.mini.copyWith(
          bounds: bounds,
          pill: true,
          pillBounds: _pillAnchor,
          pillEdge: _pillState.value?.edge,
        ),
      ),
    );
  }

  ({Rect anchor, MiniDisplay display, MiniPillEdge? edge})
  _resolvePillPlacement(
    Rect? old,
    MiniPillEdge? savedEdge,
    List<MiniDisplay> displays,
  ) {
    final match = old == null
        ? null
        : displays.where((d) => d.bounds.contains(old.topLeft)).firstOrNull;
    final display = match ?? displays.firstOrNull ?? _fallbackDisplay;
    final area = display.workArea;
    final size = _pillSize(old?.width ?? _pillDefaultWidth, display);
    final edge = platform.supportsPillTuck && match != null ? savedEdge : null;
    final x = switch (edge) {
      MiniPillEdge.left => area.left,
      MiniPillEdge.right => area.right - size.width * display.scale,
      null =>
        match != null
            ? old!.left
            : area.right - (size.width + 16) * display.scale,
    };
    final y = match != null ? old!.top : area.top + 16 * display.scale;
    final anchor = _clampPill(Offset(x, y), size, display);
    return (
      anchor: anchor,
      display: display,
      edge: _exteriorEdge(anchor, display, edge, displays),
    );
  }

  MiniPillEdge? _exteriorEdge(
    Rect anchor,
    MiniDisplay display,
    MiniPillEdge? edge,
    List<MiniDisplay> displays,
  ) {
    if (edge == null) return null;
    final tucked = _tuckedFrame(anchor, display, edge);
    final scale = display.scale;
    final area = display.workArea;
    final bottom = tucked.top + tucked.height * scale;
    final overhang = edge == MiniPillEdge.left
        ? Rect.fromLTRB(tucked.left, tucked.top, area.left, bottom)
        : Rect.fromLTRB(
            area.right,
            tucked.top,
            tucked.left + tucked.width * scale,
            bottom,
          );
    // Check physical display bounds over the whole tab height.
    return displays.any((screen) => screen.bounds.overlaps(overhang))
        ? null
        : edge;
  }

  static const _fallbackDisplay = MiniDisplay(Rect.fromLTWH(0, 0, 1050, 800));

  MiniDisplay _displayFor(MiniFrame frame, List<MiniDisplay> displays) {
    final b = frame.bounds;
    final center =
        b.topLeft +
        Offset(b.width * frame.scale / 2, b.height * frame.scale / 2);
    MiniDisplay nearest = displays.firstOrNull ?? _fallbackDisplay;
    double distance = double.infinity;
    for (final display in displays) {
      final area = display.bounds;
      if (area.contains(center)) return display;
      final point = Offset(
        center.dx.clamp(area.left, area.right),
        center.dy.clamp(area.top, area.bottom),
      );
      final candidate = (point - center).distanceSquared;
      if (candidate < distance) {
        nearest = display;
        distance = candidate;
      }
    }
    return nearest;
  }

  MiniPillEdge? _snapEdge(MiniFrame frame, MiniDisplay display) {
    final b = frame.bounds;
    final area = display.workArea;
    final left = b.left - area.left;
    final right = area.right - (b.left + b.width * frame.scale);
    if (left < _pillSnap * display.scale && left <= right) {
      return MiniPillEdge.left;
    }
    if (right < _pillSnap * display.scale) return MiniPillEdge.right;
    return null;
  }

  bool _alignRight(Rect anchor, MiniDisplay display, MiniPillEdge? edge) =>
      edge == MiniPillEdge.right ||
      (edge == null &&
          anchor.left + anchor.width * display.scale / 2 >=
              display.workArea.center.dx);

  Size _pillSize(double width, MiniDisplay display) => _fitWorkArea(
    Size(width.clamp(pillTab, pillMaxWidth), pillHeight),
    display,
  );

  Size _fitWorkArea(Size size, MiniDisplay display) => Size(
    size.width.clamp(0, display.workArea.width / display.scale),
    size.height.clamp(0, display.workArea.height / display.scale),
  );

  Rect _tuckedFrame(Rect anchor, MiniDisplay display, MiniPillEdge? edge) {
    final distance = (anchor.width - pillTab) * display.scale;
    return switch (edge) {
      MiniPillEdge.left => anchor.translate(-distance, 0),
      MiniPillEdge.right => anchor.translate(distance, 0),
      null => anchor,
    };
  }

  Rect _clampPill(Offset origin, Size size, MiniDisplay display) {
    final area = display.workArea;
    final scale = display.scale;
    return Rect.fromLTWH(
      origin.dx.clamp(
        area.left,
        (area.right - size.width * scale).clamp(area.left, area.right),
      ),
      origin.dy.clamp(
        area.top,
        (area.bottom - size.height * scale).clamp(area.top, area.bottom),
      ),
      size.width,
      size.height,
    );
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

  Future<void> togglePin() => _run(_MiniAction.togglePin, () async {
    final value = !controller.preferences.mini.pinned;
    await platform.setPinned(value);
    final prefs = controller.preferences;
    await controller.setPreferences(
      prefs.copyWith(mini: prefs.mini.copyWith(pinned: value)),
    );
  });

  Future<void> startDragging() => platform.startDragging();

  void _boundsChanged() {
    if (_disposed ||
        _closing ||
        switching ||
        _full == null ||
        _pillState.value != null) {
      return;
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), () {
      if (_disposed || switching || _full == null || _pillState.value != null) {
        return;
      }
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
    final transition = _transition;
    final bounds = await platform.getBounds();
    if (_disposed ||
        _full == null ||
        _pillState.value != null ||
        _transition != transition) {
      return;
    }
    final prefs = controller.preferences;
    if (bounds == prefs.mini.bounds) return;
    await controller.setPreferences(
      prefs.copyWith(mini: prefs.mini.copyWith(bounds: bounds)),
    );
  }

  Future<void> saveBeforeClose() async {
    _closing = true;
    _saveTimer?.cancel();
    await _transition;
    if (_pillState.value != null) {
      await _stopPillMotion();
      await _savePill();
    } else if (_full != null) {
      await _saveBounds();
    }
  }

  void dispose() {
    _disposed = true;
    _transitionWarning?.cancel();
    for (final next in _userQueue) {
      _discard(next, 'disposed');
      next.completion.complete();
    }
    _userQueue.clear();
    if (_pendingResize case final resize?) {
      _discard(resize, 'disposed');
      resize.completion.complete();
    }
    _pendingResize = null;
    _saveTimer?.cancel();
    _pillHideTimer?.cancel();
    _cancelPillSlide();
    platform.observeBounds(null);
    _liveSize.dispose();
    _pillState.dispose();
  }
}
