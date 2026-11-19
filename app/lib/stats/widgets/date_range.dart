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
  final anchor = GlobalKey();
  Future<void> custom() async {
    final box = anchor.currentContext!.findRenderObject() as RenderBox;
    final at = box.localToGlobal(Offset(0, box.size.height));
    final screen = MediaQuery.sizeOf(context);
    final range = widget.period.range(widget.now);
    final selected = await showDialog<StatsPeriod>(
      context: context,
      barrierColor: LensPalette.transparent,
      builder: (context) => Stack(
        children: [
          Positioned(
            left: (at.dx + box.size.width - 256).clamp(8, screen.width - 264),
            top: at.dy.clamp(8, screen.height - 270) + 6,
            width: 256,
            child: CustomRangePopover(range: range),
          ),
        ],
      ),
    );
    if (selected != null && mounted) widget.onChanged(selected);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    key: anchor,
    child: LensSegmented(
      label: context.strings.period,
      value: widget.period.period,
      options: {
        'today': context.strings.today,
        'week': context.strings.thisWeek2,
        'month': context.strings.thisMonth2,
        'all': context.strings.all,
        'custom': context.strings.custom,
      },
      onChanged: (v) {
        if (v == 'custom') {
          custom();
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
        SizedBox(
          height: 32,
          child: TextField(
            key: Key('range-$label'),
            controller: controller,
            style: p.text(12),
            decoration: InputDecoration(
              filled: true,
              fillColor: p['surface-1'],
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              hintText: 'YYYY-MM-DD',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
            keyboardType: TextInputType.datetime,
          ),
        ),
      ],
    );
    return Material(
      color: LensPalette.transparent,
      child: LensCard(
        radius: 12,
        padding: const EdgeInsets.all(12),
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
