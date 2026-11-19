import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../logic/period.dart';
import '../theme/palette.dart';
import 'primitives.dart';

class PeriodControl extends StatefulWidget {
  const PeriodControl({
    super.key,
    required this.period,
    required this.now,
    required this.onChanged,
  });
  final StatsPeriod period;
  final DateTime now;
  final ValueChanged<StatsPeriod> onChanged;
  @override
  State<PeriodControl> createState() => _PeriodControlState();
}

class _PeriodControlState extends State<PeriodControl> {
  final customAnchor = GlobalKey();
  final moreAnchor = GlobalKey();
  final customFocus = FocusNode();
  final moreFocus = FocusNode();

  @override
  void dispose() {
    customFocus.dispose();
    moreFocus.dispose();
    super.dispose();
  }

  Future<void> more() async {
    moreFocus.requestFocus();
    final strings = context.strings;
    final palette = LensPalette.of(context);
    final got = await LensMenu.show<String>(
      context,
      anchor: moreAnchor.currentContext!,
      width: 290,
      builder: (context) => LensMenu(
        rowHeight: 38,
        entries: [
          for (final id in StatsPeriod.shortcuts)
            LensMenuEntry(
              Row(
                children: [
                  Expanded(
                    child: Text(
                      StatsPeriod(id).labelFor(strings),
                      style: palette.text(13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    flex: 2,
                    child: Text(
                      strings.vs0(
                        StatsPeriod(id).compare(widget.now, strings)!.label,
                      ),
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: palette.text(11, palette.muted),
                    ),
                  ),
                ],
              ),
              selected: id == widget.period.period,
              onPressed: () => Navigator.pop(context, id),
            ),
        ],
      ),
    );
    if (got != null && mounted) widget.onChanged(StatsPeriod(got));
  }

  Future<void> custom() async {
    customFocus.requestFocus();
    final selected = await LensMenu.show<StatsPeriod>(
      context,
      anchor: customAnchor.currentContext!,
      alignRight: true,
      width: 264,
      builder: (_) =>
          CustomRangePopover(range: widget.period.range(widget.now)),
    );
    if (selected != null && mounted) widget.onChanged(selected);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    child: LensSegmented(
      label: context.strings.period,
      value: widget.period.isShortcut ? 'more' : widget.period.period,
      menu: (option: 'more', anchor: moreAnchor),
      anchors: {'custom': customAnchor},
      focusNodes: {'more': moreFocus, 'custom': customFocus},
      options: {
        'today': context.strings.today,
        'week': context.strings.thisWeek2,
        'month': context.strings.thisMonth2,
        'all': context.strings.all,
        'more': widget.period.isShortcut
            ? widget.period.labelFor(context.strings)
            : context.strings.morePeriods,
        'custom': context.strings.custom,
      },
      onChanged: (v) {
        if (v == 'custom') {
          custom();
        } else if (v == 'more') {
          more();
        } else {
          widget.onChanged(StatsPeriod(v));
        }
      },
    ),
  );
}

class CustomRangePopover extends StatefulWidget {
  const CustomRangePopover({super.key, required this.range});
  final DayRange range;
  @override
  State<CustomRangePopover> createState() => _CustomRangePopoverState();
}

class _CustomRangePopoverState extends State<CustomRangePopover> {
  late final from = TextEditingController(text: widget.range.from ?? '');
  late final to = TextEditingController(text: widget.range.to ?? '');
  String? error;
  @override
  void dispose() {
    from.dispose();
    to.dispose();
    super.dispose();
  }

  bool valid(String value) =>
      value.isEmpty ||
      RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) &&
          DateTime.tryParse(value) != null &&
          dayKey(DateTime.parse(value)) == value;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    Widget input(String label, TextEditingController controller) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: p.text(11, p.muted, FontWeight.w500)),
        const SizedBox(height: 4),
        LensInput(
          key: Key('range-$label'),
          size: 'sm',
          controller: controller,
          hint: 'YYYY-MM-DD',
          label: label,
          error: error != null,
          autofocus: identical(controller, from),
          keyboardType: TextInputType.datetime,
        ),
      ],
    );
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            input(context.strings.from, from),
            const SizedBox(height: 8),
            input(context.strings.to, to),
            if (error != null) Text(error!, style: p.text(11, p['danger'])),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                LensButton(
                  label: context.strings.clear,
                  variant: 'ghost',
                  size: 'xs',
                  onPressed: () {
                    from.clear();
                    to.clear();
                    setState(() => error = null);
                  },
                ),
                LensButton(
                  label: context.strings.apply,
                  variant: 'primary',
                  size: 'xs',
                  icon: Icons.check,
                  onPressed: () {
                    if (!valid(from.text) ||
                        !valid(to.text) ||
                        from.text.isNotEmpty &&
                            to.text.isNotEmpty &&
                            from.text.compareTo(to.text) > 0) {
                      setState(
                        () => error = context.strings.enterAValidDateRange,
                      );
                      return;
                    }
                    Navigator.of(context).pop(
                      StatsPeriod(
                        'custom',
                        from.text.isEmpty ? null : from.text,
                        to.text.isEmpty ? null : to.text,
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
