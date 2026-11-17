import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../smooth_wheel.dart';
import '../theme/palette.dart';
import 'primitives.dart';

class FilterOption {
  const FilterOption(
    this.value,
    this.label, {
    this.tool,
    this.tokens,
    this.tooltip,
  });
  final String value, label;
  final String? tool, tooltip;
  final int? tokens;
}

class FilterPick extends StatefulWidget {
  const FilterPick({
    super.key,
    required this.label,
    required this.options,
    required this.onPick,
    this.unitSystem = 'chinese',
  });
  final String label, unitSystem;
  final List<FilterOption> options;
  final ValueChanged<String> onPick;
  @override
  State<FilterPick> createState() => _FilterPickState();
}

class _FilterPickState extends State<FilterPick> {
  final anchor = GlobalKey();
  Future<void> open() async {
    final box = anchor.currentContext!.findRenderObject() as RenderBox;
    final at = box.localToGlobal(Offset(0, box.size.height));
    final size = MediaQuery.sizeOf(context);
    final value = await showDialog<String>(
      context: context,
      barrierColor: LensPalette.transparent,
      animationStyle: AnimationStyle.noAnimation,
      builder: (_) => Stack(
        children: [
          Positioned(
            left: at.dx.clamp(8, size.width - 228),
            top: (at.dy + 6).clamp(8, size.height - 308),
            width: 220,
            child: _FilterPopup(
              options: widget.options,
              unitSystem: widget.unitSystem,
            ),
          ),
        ],
      ),
    );
    if (mounted && value != null) widget.onPick(value);
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return Container(
      key: anchor,
      height: 30,
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(8),
        boxShadow: p.smallShadow,
      ),
      child: LensFocusOutline(
        child: TextButton(
          onPressed: widget.options.isEmpty ? null : open,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.only(left: 12, right: 10),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            foregroundColor: p.secondary,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.label, style: p.text(13, p.secondary)),
              const SizedBox(width: 6),
              Icon(Icons.expand_more, size: 12, color: p.muted),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterPopup extends StatefulWidget {
  const _FilterPopup({required this.options, required this.unitSystem});
  final List<FilterOption> options;
  final String unitSystem;
  @override
  State<_FilterPopup> createState() => _FilterPopupState();
}

class _FilterPopupState extends State<_FilterPopup> {
  final scroll = SmoothWheelController();
  late final nodes = List.generate(widget.options.length, (_) => FocusNode());
  @override
  void dispose() {
    scroll.dispose();
    for (final node in nodes) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return Material(
      color: p['surface-3'],
      borderRadius: BorderRadius.circular(12),
      elevation: 8,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 300),
        child: Focus(
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.escape) {
              Navigator.pop(context);
              return KeyEventResult.handled;
            }
            if ([
              LogicalKeyboardKey.arrowDown,
              LogicalKeyboardKey.arrowUp,
            ].contains(event.logicalKey)) {
              final at = nodes.indexWhere((n) => n.hasFocus);
              final index =
                  (at +
                      (event.logicalKey == LogicalKeyboardKey.arrowDown
                          ? 1
                          : nodes.length - 1)) %
                  nodes.length;
              nodes[index].requestFocus();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: ListView.builder(
            controller: scroll,
            shrinkWrap: true,
            padding: const EdgeInsets.all(6),
            itemCount: widget.options.length,
            itemBuilder: (context, i) {
              final o = widget.options[i];
              return LensFocusOutline(
                child: TextButton(
                  focusNode: nodes[i],
                  autofocus: i == 0,
                  onPressed: () => Navigator.pop(context, o.value),
                  style: TextButton.styleFrom(
                    foregroundColor: p.ink,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 34),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Row(
                    children: [
                      if (o.tool != null) ...[
                        ToolTile(o.tool!, size: 16),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Tooltip(
                          message: o.tooltip ?? o.label,
                          child: Text(
                            o.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: p.text(13),
                          ),
                        ),
                      ),
                      if (o.tokens != null)
                        TokenText(
                          o.tokens,
                          unitSystem: widget.unitSystem,
                          style: p.text(12, p.muted).copyWith(height: 1.4),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class FilterTag extends StatelessWidget {
  const FilterTag({
    super.key,
    required this.label,
    required this.value,
    required this.onRemove,
    this.tool,
  });
  final String label, value;
  final String? tool;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return Container(
      height: 30,
      padding: const EdgeInsets.only(left: 10, right: 6),
      decoration: BoxDecoration(
        color: p['clay-wash'],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: p.text(13, p['clay-ink'].withValues(alpha: .7))),
          const SizedBox(width: 6),
          if (tool != null) ...[
            ToolTile(tool!, size: 16),
            const SizedBox(width: 6),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: p.text(13, p['clay-ink'], FontWeight.w500),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 20,
            height: 20,
            child: LensFocusOutline(
              child: IconButton(
                tooltip: '去掉$label筛选',
                padding: EdgeInsets.zero,
                iconSize: 14,
                onPressed: onRemove,
                icon: Icon(Icons.close, color: p['clay-ink']),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
