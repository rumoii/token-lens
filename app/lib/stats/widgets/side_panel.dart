import 'primitives.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../smooth_wheel.dart';
import '../theme/palette.dart';

typedef PanelHeading = ({String title, String hint, String? tooltip});

Future<void> showLensPanel(
  BuildContext context, {
  required String title,
  required String hint,
  required Widget icon,
  required Widget body,
  String label = '会话详情',
  ValueNotifier<PanelHeading>? heading,
}) {
  final narrow = MediaQuery.sizeOf(context).width < 768;
  final reduced = MediaQuery.disableAnimationsOf(context);
  return Navigator.of(context).push<void>(
    _LensPanelRoute(
      reduced: reduced,
      barrierLabel: '关闭$label',
      pageBuilder: (context, _, _) => heading == null
          ? _LensPanel(
              label: label,
              title: title,
              hint: hint,
              icon: icon,
              body: body,
              narrow: narrow,
            )
          : ValueListenableBuilder<PanelHeading>(
              valueListenable: heading,
              builder: (context, value, _) => _LensPanel(
                label: label,
                title: value.title,
                hint: value.hint,
                titleTooltip: value.tooltip,
                icon: icon,
                body: body,
                narrow: narrow,
              ),
            ),
      transitionBuilder: (context, animation, _, child) => AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          final value = const Cubic(.16, 1, .3, 1).transform(animation.value);
          return Opacity(
            opacity: value,
            child: Transform.translate(
              offset: narrow
                  ? Offset(0, 60 * (1 - value))
                  : Offset(40 * (1 - value), 0),
              child: child,
            ),
          );
        },
      ),
    ),
  );
}

class _LensPanelRoute extends RawDialogRoute<void> {
  _LensPanelRoute({
    required super.pageBuilder,
    required super.transitionBuilder,
    required bool reduced,
    required String barrierLabel,
  }) : super(
         barrierDismissible: true,
         barrierLabel: barrierLabel,
         barrierColor: Colors.black.withValues(alpha: .3),
         traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
         transitionDuration: reduced
             ? Duration.zero
             : const Duration(milliseconds: 260),
       );
  @override
  Curve get barrierCurve =>
      const Interval(0, 160 / 260, curve: LensTokens.ease);
  @override
  Duration get reverseTransitionDuration => Duration.zero;
}

class _LensPanel extends StatefulWidget {
  const _LensPanel({
    required this.label,
    required this.title,
    required this.hint,
    required this.icon,
    required this.body,
    required this.narrow,
    this.titleTooltip,
  });
  final String label, title, hint;
  final Widget icon, body;
  final bool narrow;
  final String? titleTooltip;
  @override
  State<_LensPanel> createState() => _LensPanelState();
}

class _LensPanelState extends State<_LensPanel> {
  final scroll = SmoothWheelController();
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return Stack(
      children: [
        Positioned(
          right: 0,
          left: widget.narrow ? 0 : null,
          top: widget.narrow ? 56 : 0,
          bottom: 0,
          width: widget.narrow ? null : 460,
          child: Semantics(
            label: widget.label,
            scopesRoute: true,
            namesRoute: true,
            explicitChildNodes: true,
            child: Material(
              color: p['surface-1'],
              borderRadius: widget.narrow
                  ? const BorderRadius.vertical(top: Radius.circular(16))
                  : null,
              clipBehavior: Clip.antiAlias,
              child: Focus(
                onKeyEvent: (_, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape) {
                    Navigator.pop(context);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            width: LensPalette.hairline(context),
                            color: p['line-soft'],
                          ),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          widget.icon,
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Tooltip(
                                  message: widget.titleTooltip ?? widget.title,
                                  child: Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: p.text(18, null, FontWeight.w600),
                                  ),
                                ),
                                Text(widget.hint, style: p.text(12.5, p.muted)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Focus(
                            canRequestFocus: false,
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              height: 30,
                              width: 30,
                              child: LensFocusOutline(
                                child: IconButton(
                                  autofocus: true,
                                  tooltip: '关闭',
                                  padding: EdgeInsets.zero,
                                  onPressed: () => Navigator.pop(context),
                                  icon: Icon(
                                    Icons.close,
                                    size: 16,
                                    color: p.muted,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        key: const Key('session-panel-scroll'),
                        controller: scroll,
                        padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
                        child: widget.body,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
