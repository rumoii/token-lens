import 'package:flutter/material.dart';

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
    this.searchable = true,
    this.selected,
    this.selectedLabel,
    this.selectedTool,
    this.onClear,
    this.size = 'md',
  });

  final String label, unitSystem, size;
  final List<FilterOption> options;
  final ValueChanged<String> onPick;
  final bool searchable;
  final String? selected, selectedLabel, selectedTool;
  final VoidCallback? onClear;

  @override
  State<FilterPick> createState() => _FilterPickState();
}

class _FilterPickState extends State<FilterPick> {
  final anchor = GlobalKey();
  final focus = FocusNode();

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  Future<void> open() async {
    focus.requestFocus();
    final options = widget.options;
    final value = await LensMenu.show<String>(
      context,
      anchor: anchor.currentContext!,
      builder: (context) {
        final p = LensPalette.of(context);
        return LensMenu(
          searchable: widget.searchable && options.length > 8,
          matches: (i, query) => options[i].label.toLowerCase().contains(query),
          entries: [
            for (final option in options)
              LensMenuEntry(
                Row(
                  children: [
                    if (option.tool != null) ...[
                      ToolTile(option.tool!, size: 16),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Tooltip(
                        message: option.tooltip ?? option.label,
                        child: Text(
                          option.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: p.text(13),
                        ),
                      ),
                    ),
                    if (option.tokens != null)
                      TokenText(
                        option.tokens,
                        unitSystem: widget.unitSystem,
                        style: p.text(12, p.muted),
                      ),
                  ],
                ),
                selected: option.value == widget.selected,
                onPressed: () => Navigator.pop(context, option.value),
              ),
          ],
        );
      },
    );
    if (mounted && value != null) widget.onPick(value);
  }

  @override
  Widget build(BuildContext context) => LensFilterTrigger(
    key: anchor,
    label: widget.label,
    value: widget.selectedLabel,
    tool: widget.selectedTool,
    onPressed: widget.options.isEmpty ? null : open,
    onClear: widget.onClear,
    size: widget.size,
    focusNode: focus,
  );
}

class FilterTag extends StatelessWidget {
  const FilterTag({
    super.key,
    required this.label,
    required this.value,
    required this.onRemove,
  });
  final String label, value;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => LensFilterTrigger(
    label: label,
    value: value,
    onPressed: null,
    onClear: onRemove,
    size: 'sm',
  );
}
