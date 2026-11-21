part of 'primitives.dart';

class LensMenuEntry {
  const LensMenuEntry(
    this.child, {
    this.key,
    this.onPressed,
    this.selected,
    this.checked,
  });

  final Widget child;
  final Key? key;
  final VoidCallback? onPressed;
  final bool? selected, checked;
}

class LensMenu extends StatefulWidget {
  const LensMenu({
    super.key,
    required this.entries,
    this.searchable = false,
    this.matches,
    this.rowHeight = 32,
  });

  final List<LensMenuEntry> entries;
  final bool searchable;
  final bool Function(int index, String query)? matches;
  final double rowHeight;

  static Future<T?> show<T>(
    BuildContext context, {
    required BuildContext anchor,
    required WidgetBuilder builder,
    double width = 220,
    double maxHeight = 300,
    bool alignRight = false,
    bool scaleFromAnchor = false,
  }) {
    final overlay = Navigator.of(context, rootNavigator: true).overlay!;
    final bounds = overlay.context.findRenderObject()!;
    final box = anchor.findRenderObject()! as RenderBox;
    final position =
        box.localToGlobal(Offset.zero, ancestor: bounds) & box.size;
    return showDialog<T>(
      context: context,
      barrierColor: LensPalette.transparent,
      animationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : AnimationStyle(
              duration: scaleFromAnchor ? LensTokens.tip : LensTokens.fast,
              curve: LensTokens.ease,
            ),
      builder: (context) => CustomSingleChildLayout(
        delegate: _LensPopoverPosition(position, width, maxHeight, alignRight),
        child: Builder(
          builder: (context) {
            final popover = LensPopover(child: Builder(builder: builder));
            if (!scaleFromAnchor || MediaQuery.disableAnimationsOf(context)) {
              return popover;
            }
            return ScaleTransition(
              scale: Tween<double>(
                begin: .95,
                end: 1,
              ).animate(ModalRoute.of(context)!.animation!),
              alignment: alignRight ? Alignment.topRight : Alignment.topLeft,
              child: popover,
            );
          },
        ),
      ),
    );
  }

  @override
  State<LensMenu> createState() => _LensMenuState();
}

class _LensPopoverPosition extends SingleChildLayoutDelegate {
  const _LensPopoverPosition(
    this.anchor,
    this.width,
    this.height,
    this.alignRight,
  );
  final Rect anchor;
  final double width, height;
  final bool alignRight;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        minWidth: math.min(width, math.max(0, constraints.maxWidth - 16)),
        maxWidth: math.min(width, math.max(0, constraints.maxWidth - 16)),
        maxHeight: math.min(height, math.max(0, constraints.maxHeight - 16)),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = alignRight ? anchor.right - childSize.width : anchor.left;
    final below = anchor.bottom + 6;
    final above = anchor.top - childSize.height - 6;
    final maxTop = size.height - childSize.height - 8;
    final top = below > maxTop && above >= 8 ? above : below;
    return Offset(
      left.clamp(8, math.max(8, size.width - childSize.width - 8)),
      top.clamp(8, math.max(8, maxTop)),
    );
  }

  @override
  bool shouldRelayout(_LensPopoverPosition oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.width != width ||
      oldDelegate.height != height ||
      oldDelegate.alignRight != alignRight;
}

class LensPopover extends StatelessWidget {
  const LensPopover({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: p.shadow('popover'),
      ),
      child: Material(
        color: p['surface-3'],
        shape: p.popoverShape,
        child: child,
      ),
    );
  }
}

class _LensMenuState extends State<LensMenu> {
  final scroll = SmoothWheelController();
  final searchFocus = FocusNode();
  final search = TextEditingController();
  final Map<int, FocusNode> nodes = {};
  String query = '';

  @override
  void dispose() {
    scroll.dispose();
    searchFocus.dispose();
    search.dispose();
    for (final node in nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _node(int index) => nodes.putIfAbsent(index, FocusNode.new);

  void _focusRow(List<int> visible, int index) {
    final node = _node(index);
    if (node.context case final row?) {
      node.requestFocus();
      Scrollable.ensureVisible(row);
    } else if (scroll.hasClients) {
      scroll.jumpTo(
        (visible.indexOf(index) * widget.rowHeight).clamp(
          0,
          scroll.position.maxScrollExtent,
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) node.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = [
      for (var i = 0; i < widget.entries.length; i++)
        if (widget.matches?.call(i, query) ?? true) i,
    ];
    final enabled = [
      for (final index in visible)
        if (widget.entries[index].onPressed != null) index,
    ];
    final initial = enabled.isEmpty ? null : enabled.first;
    Widget row(int index) {
      final entry = widget.entries[index];
      return SizedBox(
        height: widget.rowHeight,
        child: LensMenuRow(
          key: entry.key,
          entry: entry,
          focusNode: _node(index),
          autofocus: !widget.searchable && index == initial,
        ),
      );
    }

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        if (enabled.isEmpty) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.enter &&
            searchFocus.hasFocus) {
          widget.entries[initial!].onPressed!();
          return KeyEventResult.handled;
        }
        final at = enabled.indexWhere(
          (index) => nodes[index]?.hasFocus ?? false,
        );
        final next = switch (event.logicalKey) {
          LogicalKeyboardKey.home => 0,
          LogicalKeyboardKey.end => enabled.length - 1,
          LogicalKeyboardKey.arrowDown => (at + 1) % enabled.length,
          LogicalKeyboardKey.arrowUp => (at <= 0 ? enabled.length : at) - 1,
          _ => null,
        };
        if (next == null) return KeyEventResult.ignored;
        _focusRow(visible, enabled[next]);
        return KeyEventResult.handled;
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.searchable)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: LensInput(
                controller: search,
                autofocus: true,
                focusNode: searchFocus,
                size: 'sm',
                search: true,
                hint: context.strings.filterSearch,
                onChanged: (value) {
                  if (scroll.hasClients) scroll.jumpTo(0);
                  setState(() => query = value.trim().toLowerCase());
                },
                onSubmitted: (_) {
                  if (initial != null) widget.entries[initial].onPressed!();
                },
              ),
            ),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                context.strings.noMatchingOptions,
                style: LensPalette.of(context).text(12),
              ),
            )
          else
            Flexible(
              child: widget.searchable
                  ? ListView.builder(
                      controller: scroll,
                      shrinkWrap: true,
                      itemExtent: widget.rowHeight,
                      padding: const EdgeInsets.all(6),
                      itemCount: visible.length,
                      itemBuilder: (context, i) => row(visible[i]),
                    )
                  : SingleChildScrollView(
                      controller: scroll,
                      padding: const EdgeInsets.all(6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: visible.map(row).toList(),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}

class LensMenuRow extends StatelessWidget {
  const LensMenuRow({
    super.key,
    required this.entry,
    this.focusNode,
    this.autofocus = false,
  });

  final LensMenuEntry entry;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return Semantics(
      selected: entry.selected,
      checked: entry.checked,
      child: _LensControl(
        radius: 4,
        onPressed: entry.onPressed,
        focusNode: focusNode,
        autofocus: autofocus,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            if (entry.selected != null || entry.checked != null)
              SizedBox(
                width: 22,
                child: entry.selected == true || entry.checked == true
                    ? Icon(Icons.check, color: p['clay'], size: 14)
                    : null,
              ),
            Expanded(child: entry.child),
          ],
        ),
      ),
    );
  }
}

class LensFilterTrigger extends StatelessWidget {
  const LensFilterTrigger({
    super.key,
    required this.label,
    required this.onPressed,
    this.onClear,
    this.value,
    this.tool,
    this.size = 'md',
    this.focusNode,
  });

  final String label, size;
  final String? value, tool;
  final VoidCallback? onPressed, onClear;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final selected = value != null;
    final radius = _controlRadius(size);
    final caption = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: p.text(13, selected ? p['clay-ink'] : p.secondary)),
        if (tool != null) ...[
          const SizedBox(width: 6),
          ToolTile(tool!, size: 16),
        ],
        if (selected) ...[
          const SizedBox(width: 6),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                value!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: p.text(13, p['clay-ink'], FontWeight.w500),
              ),
            ),
          ),
        ],
        if (onPressed != null || !selected) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.expand_more,
            size: 14,
            color: selected ? p['clay-ink'] : p.muted,
          ),
        ],
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? p['clay-wash'] : p['fill-hover'],
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SizedBox(
              height: _controlHeight(size),
              child: onPressed == null && selected
                  ? Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: caption,
                    )
                  : Semantics(
                      selected: selected,
                      child: _LensControl(
                        radius: radius,
                        focusNode: focusNode,
                        onPressed: onPressed,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: caption,
                      ),
                    ),
            ),
          ),
          if (onClear != null)
            Padding(
              padding: const EdgeInsets.only(right: 3),
              child: LensIconButton(
                icon: Icons.close,
                tooltip: context.strings.remove0Filter(label),
                size: 'xs',
                color: p['clay-ink'],
                onPressed: onClear,
              ),
            ),
        ],
      ),
    );
  }
}
