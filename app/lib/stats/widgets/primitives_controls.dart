part of 'primitives.dart';

const _hoverTime = Duration(milliseconds: 150);
const _hoverCurve = Cubic(.16, 1, .3, 1);

class LensHeaderControls extends StatelessWidget {
  const LensHeaderControls({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) =>
      children.length < 2 || MediaQuery.sizeOf(context).width < 1180
      ? Wrap(spacing: 10, runSpacing: 10, children: children)
      : Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            ...children.take(children.length - 1),
            Flexible(child: children.last),
          ],
        );
}

class LensPageHeader extends StatelessWidget {
  const LensPageHeader({
    super.key,
    required this.title,
    required this.controls,
    required this.description,
    this.spacing = 6,
  });

  final Widget title, controls, description;
  final double spacing;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: spacing,
    children: [
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 12,
        children: [title, controls],
      ),
      description,
    ],
  );
}

Duration _hoverDuration(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : _hoverTime;

double _controlHeight(String size) => switch (size) {
  'xs' => 24,
  'sm' => 28,
  'lg' => 40,
  _ => 32,
};

double _controlRadius(String size) => switch (size) {
  'xs' => 6,
  'lg' => 10,
  _ => 8,
};

Color _controlFill(LensPalette p, String variant, Set<WidgetState> states) {
  if (variant == 'primary') {
    return p[states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.pressed)
        ? 'clay-hover'
        : 'clay'];
  }
  if (states.contains(WidgetState.pressed)) return p['fill-active'];
  if (variant == 'ghost') {
    return states.contains(WidgetState.hovered)
        ? p['fill-hover']
        : LensPalette.transparent;
  }
  return p[states.contains(WidgetState.hovered) ? 'fill-active' : 'fill-hover'];
}

class _LensControl extends StatelessWidget {
  const _LensControl({
    required this.child,
    required this.onPressed,
    required this.radius,
    this.focusNode,
    this.onLongPress,
    this.padding = EdgeInsets.zero,
    this.fill,
    this.insetFocus = false,
    this.autofocus = false,
  });

  final Widget child;
  final VoidCallback? onPressed, onLongPress;
  final FocusNode? focusNode;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color Function(LensPalette, Set<WidgetState>)? fill;
  final bool insetFocus, autofocus;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return Opacity(
      opacity: onPressed == null ? LensTokens.disabledOpacity : 1,
      child: LensFocusOutline(
        radius: radius,
        inset: insetFocus,
        child: LensPressFeedback(
          builder: (states) => TextButton(
            autofocus: autofocus,
            focusNode: focusNode,
            statesController: states,
            onPressed: onPressed,
            onLongPress: onLongPress,
            style:
                TextButton.styleFrom(
                  foregroundColor: p.secondary,
                  disabledForegroundColor: p.secondary,
                  minimumSize: Size.zero,
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.standard,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(radius),
                  ),
                  animationDuration: Duration.zero,
                ).copyWith(
                  overlayColor: const WidgetStatePropertyAll(
                    LensPalette.transparent,
                  ),
                ),
            child: ListenableBuilder(
              listenable: states,
              builder: (context, child) => AnimatedContainer(
                duration: _hoverDuration(context),
                curve: _hoverCurve,
                padding: padding,
                decoration: BoxDecoration(
                  color:
                      fill?.call(p, states.value) ??
                      _controlFill(p, 'ghost', states.value),
                  borderRadius: BorderRadius.circular(radius),
                ),
                child: child,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class LensIconButton extends StatelessWidget {
  const LensIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 'md',
    this.tonal = false,
    this.color,
    this.focusNode,
    this.insetFocus = false,
    this.autofocus = false,
  });

  final IconData icon;
  final String tooltip, size;
  final VoidCallback? onPressed;
  final bool tonal, insetFocus, autofocus;
  final Color? color;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final height = _controlHeight(size);
    return Tooltip(
      message: tooltip,
      child: _LensControl(
        radius: _controlRadius(size),
        insetFocus: insetFocus,
        autofocus: autofocus,
        onPressed: onPressed,
        focusNode: focusNode,
        fill: (p, states) =>
            _controlFill(p, tonal ? 'secondary' : 'ghost', states),
        child: SizedBox.square(
          dimension: height,
          child: Icon(
            icon,
            size: size == 'xs' ? 14 : 16,
            color: color ?? p.muted,
          ),
        ),
      ),
    );
  }
}

class LensSortDirection extends StatelessWidget {
  const LensSortDirection({
    super.key,
    required this.ascending,
    required this.onPressed,
    this.tooltip,
    this.size = 'md',
  });

  final bool ascending;
  final VoidCallback? onPressed;
  final String? tooltip;
  final String size;

  @override
  Widget build(BuildContext context) => LensIconButton(
    icon: ascending ? Icons.arrow_upward : Icons.arrow_downward,
    tooltip:
        tooltip ??
        (ascending
            ? context.strings.sortAscending
            : context.strings.sortDescending),
    onPressed: onPressed,
    size: size,
    tonal: true,
  );
}

class LensChip extends StatelessWidget {
  const LensChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.count,
    this.size = 'md',
  });

  final String label;
  final bool selected;
  final int? count;
  final VoidCallback? onPressed;
  final String size;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final height = _controlHeight(size);
    final small = size == 'sm';
    return Semantics(
      selected: selected,
      child: _LensControl(
        radius: height / 2,
        onPressed: onPressed,
        padding: EdgeInsets.symmetric(horizontal: small ? 10 : 12),
        fill: (p, states) => selected && !states.contains(WidgetState.pressed)
            ? p[states.contains(WidgetState.hovered) ? 'clay-20' : 'clay-wash']
            : _controlFill(p, 'secondary', states),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: height),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: p.text(
                  small ? 12 : 12.5,
                  selected ? p['clay-ink'] : p.secondary,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 5),
                Text('$count', style: p.text(11, p.muted)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class LensInput extends StatelessWidget {
  const LensInput({
    super.key,
    required this.controller,
    this.hint,
    this.label,
    this.onChanged,
    this.onSubmitted,
    this.onClear,
    this.clearLabel,
    this.hintAccessory,
    this.focusNode,
    this.keyboardType,
    this.size = 'md',
    this.search = false,
    this.error = false,
    this.enabled = true,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged, onSubmitted;
  final VoidCallback? onClear;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final String? hint, label, clearLabel;
  final Widget? hintAccessory;
  final String size;
  final bool search, error, enabled, autofocus;

  void _clear() {
    controller.clear();
    if (onClear case final callback?) {
      callback();
    } else {
      onChanged?.call('');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (!enabled ||
            !search ||
            controller.text.isEmpty ||
            event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        _clear();
        return KeyEventResult.handled;
      },
      child: Opacity(
        opacity: enabled ? 1 : LensTokens.disabledOpacity,
        child: LensFocusOutline(
          error: error,
          radius: _controlRadius(size),
          child: SizedBox(
            height: _controlHeight(size),
            child: ValueListenableBuilder(
              valueListenable: controller,
              builder: (context, value, _) => Semantics(
                label: label,
                child: TextField(
                  controller: controller,
                  autofocus: autofocus,
                  focusNode: focusNode,
                  enabled: enabled,
                  cursorColor: p['clay'],
                  keyboardType: keyboardType ?? TextInputType.text,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  inputFormatters: [
                    FilteringTextInputFormatter.singleLineFormatter,
                  ],
                  textAlignVertical: TextAlignVertical.center,
                  style: p.text(13),
                  onSubmitted: onSubmitted,
                  onChanged: onChanged,
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: p.text(13, p.muted),
                    filled: true,
                    isDense: true,
                    fillColor: p['fill-hover'],
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    prefixIconConstraints: const BoxConstraints(minWidth: 30),
                    prefixIcon: search
                        ? Icon(Icons.search, size: 15, color: p.muted)
                        : null,
                    suffixIconConstraints: const BoxConstraints(minWidth: 28),
                    suffixIcon: search && value.text.isNotEmpty
                        ? Center(
                            widthFactor: 1,
                            heightFactor: 1,
                            child: LensIconButton(
                              icon: Icons.close,
                              tooltip:
                                  clearLabel ?? context.strings.clearSearch,
                              onPressed: enabled ? _clear : null,
                              size: 'xs',
                              insetFocus: true,
                            ),
                          )
                        : hintAccessory,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(_controlRadius(size)),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LensSwitch extends StatelessWidget {
  const LensSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.child,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final toggle = onChanged == null ? null : () => onChanged!(!value);
    final track = AnimatedContainer(
      duration: duration,
      width: 44,
      height: 24,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: p[value ? 'clay' : 'line-strong'],
      ),
      child: AnimatedAlign(
        duration: duration,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: p.shadow('thumb'),
          ),
        ),
      ),
    );
    return Semantics(
      label: label,
      toggled: value,
      enabled: toggle != null,
      onTap: toggle,
      child: _LensControl(
        onPressed: toggle,
        radius: child == null ? 12 : 8,
        child: child == null
            ? track
            : Row(
                children: [
                  Expanded(child: child!),
                  const SizedBox(width: 12),
                  track,
                ],
              ),
      ),
    );
  }
}

class LensCheckbox extends StatelessWidget {
  const LensCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.child,
    this.leading = true,
    this.padding = EdgeInsets.zero,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;
  final Widget? child;
  final bool leading;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final toggle = onChanged == null ? null : () => onChanged!(!value);
    final box = AnimatedContainer(
      duration: _hoverDuration(context),
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        color: value ? p['clay'] : LensPalette.transparent,
        border: value ? null : Border.all(color: p['line-heavy'], width: 1.5),
      ),
      child: value
          ? const Icon(Icons.check, color: Colors.white, size: 12)
          : null,
    );
    return Semantics(
      label: label,
      checked: value,
      enabled: toggle != null,
      onTap: toggle,
      child: _LensControl(
        onPressed: toggle,
        radius: child == null ? 4 : 8,
        padding: padding,
        child: child == null
            ? box
            : Row(
                children: leading
                    ? [box, const SizedBox(width: 8), Expanded(child: child!)]
                    : [Expanded(child: child!), const SizedBox(width: 8), box],
              ),
      ),
    );
  }
}

class LensDisclosure extends StatelessWidget {
  const LensDisclosure({
    super.key,
    required this.expanded,
    required this.onPressed,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.showArrow = true,
  });

  final bool expanded;
  final VoidCallback? onPressed;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool showArrow;

  @override
  Widget build(BuildContext context) => Semantics(
    expanded: expanded,
    child: _LensControl(
      radius: 8,
      padding: padding,
      onPressed: onPressed,
      child: !showArrow
          ? child
          : Align(
              alignment: AlignmentDirectional.centerStart,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LensDisclosureArrow(expanded: expanded),
                  const SizedBox(width: 6),
                  Flexible(child: child),
                ],
              ),
            ),
    ),
  );
}

class LensDisclosureArrow extends StatelessWidget {
  const LensDisclosureArrow({super.key, required this.expanded});
  final bool expanded;

  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: expanded ? .25 : 0,
    duration: _hoverDuration(context),
    curve: _hoverCurve,
    child: Icon(
      Icons.chevron_right,
      size: 14,
      color: LensPalette.of(context).muted,
    ),
  );
}

class LensThemeToggle extends StatelessWidget {
  const LensThemeToggle({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final selected = value == 'light' || value == 'dark';
    final duration = _hoverDuration(context);
    return Container(
      width: 52,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: p['segment-track'],
        borderRadius: BorderRadius.circular(14),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedAlign(
                alignment: value == 'dark'
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                duration: duration,
                curve: _hoverCurve,
                child: AnimatedOpacity(
                  opacity: selected ? 1 : 0,
                  duration: duration,
                  child: DecoratedBox(
                    key: const Key('theme-thumb'),
                    decoration: BoxDecoration(
                      color: p['segment-thumb'],
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: p.shadow('thumb'),
                    ),
                    child: const SizedBox.square(dimension: 24),
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (final (mode, label, icon) in [
                ('light', context.strings.light, Icons.light_mode_outlined),
                ('dark', context.strings.dark, Icons.dark_mode_outlined),
              ])
                Semantics(
                  selected: value == mode,
                  child: Tooltip(
                    message: context.strings.themeShortcut(label),
                    child: _LensControl(
                      radius: 12,
                      onPressed: () => onChanged(mode),
                      onLongPress: () => onChanged('system'),
                      child: SizedBox.square(
                        dimension: 24,
                        child: Icon(
                          icon,
                          size: 15,
                          color: value == mode ? p.ink : p.secondary,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
