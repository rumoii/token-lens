import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals, ValueListenable;
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';
import '../../stats_controller.dart';
import '../../stats_gateway.dart';
import '../logic/display.dart';
import '../logic/format.dart';
import '../logic/tool_order.dart';
import '../logic/tools.dart';
import '../preferences.dart';
import '../theme/palette.dart';
import '../widgets/motion.dart';
import '../widgets/primitives.dart';
import '../widgets/request_log.dart';
import 'mini_window.dart';

part 'mini_rows.dart';
part 'mini_motion.dart';
part 'mini_chart.dart';
part 'mini_pill.dart';

enum _MiniSetting { refresh, chart, projects }

class MiniPanel extends StatefulWidget {
  const MiniPanel({
    super.key,
    required this.controller,
    required this.window,
    required this.onExpand,
    required this.onProject,
    required this.onRequest,
  });

  final StatsController controller;
  final MiniWindow window;
  final VoidCallback onExpand;
  final ValueChanged<String?> onProject;
  final ValueChanged<StatsRequest> onRequest;

  @override
  State<MiniPanel> createState() => _MiniPanelState();
}

class _MiniPanelState extends State<MiniPanel> {
  bool _requests = false, _hovered = false;
  int? _chartSelection;
  final _settings = GlobalKey();

  StatsController get c => widget.controller;
  late StatsMiniUsage? _usage = c.miniUsage;
  final _projectFlashes = <String?, int>{};
  final _requestFlashes = <String, int>{};
  Timer? _flashExpiry;

  @override
  void initState() {
    super.initState();
    c.addListener(_dataChanged);
  }

  @override
  void didUpdateWidget(MiniPanel old) {
    super.didUpdateWidget(old);
    if (old.controller == c) return;
    old.controller.removeListener(_dataChanged);
    _usage = c.miniUsage;
    _chartSelection = null;
    _flashExpiry?.cancel();
    _projectFlashes.clear();
    _requestFlashes.clear();
    c.addListener(_dataChanged);
  }

  @override
  void dispose() {
    c.removeListener(_dataChanged);
    _flashExpiry?.cancel();
    super.dispose();
  }

  void _dataChanged() {
    final before = _usage, next = c.miniUsage;
    if (before?.minutes.length != next?.minutes.length) _chartSelection = null;
    if (c.miniRevision > 0 &&
        !identical(before, next) &&
        before != null &&
        next != null) {
      final tokens = {for (final p in before.projects) p.key: p.grossTokens};
      final ids = before.requests.items.map((r) => r.id).toSet();
      _projectFlashes.removeWhere(
        (key, _) => !next.projects.any((p) => p.key == key),
      );
      _requestFlashes.removeWhere(
        (id, _) => !next.requests.items.any((r) => r.id == id),
      );
      for (final p in next.projects) {
        if (p.grossTokens > (tokens[p.key] ?? 0)) {
          _projectFlashes[p.key] = c.miniRevision;
        }
      }
      for (final r in next.requests.items) {
        if (!ids.contains(r.id)) _requestFlashes[r.id] = c.miniRevision;
      }
      if (_projectFlashes.containsValue(c.miniRevision) ||
          _requestFlashes.containsValue(c.miniRevision)) {
        _flashExpiry?.cancel();
        _flashExpiry = Timer(_MiniFlashState.duration, () {
          _projectFlashes.clear();
          _requestFlashes.clear();
        });
      }
    }
    setState(() => _usage = next);
  }

  Future<void> _openSettings() async {
    final s = context.strings;
    final p = LensPalette.of(context);
    final mini = c.preferences.mini;
    final selection = await LensMenu.show<(_MiniSetting, int)>(
      context,
      anchor: _settings.currentContext!,
      width: 210,
      maxHeight: 492,
      alignRight: true,
      scaleFromAnchor: true,
      builder: (popup) {
        LensMenuEntry heading(String text) => LensMenuEntry(
          Text(text, style: p.text(11, p.muted, FontWeight.w600)),
        );
        LensMenuEntry option(
          String text,
          _MiniSetting setting,
          int n,
          bool checked,
        ) => LensMenuEntry(
          Text(text),
          checked: checked,
          onPressed: () => Navigator.of(popup).pop((setting, n)),
        );
        return LensMenu(
          rowHeight: 28,
          entries: [
            heading(s.miniRefreshEvery),
            for (final seconds in MiniPreferences.intervals)
              option(
                s.miniInterval(seconds),
                _MiniSetting.refresh,
                seconds,
                mini.seconds == seconds,
              ),
            heading(s.miniChartRange),
            for (final minutes in MiniPreferences.chartRanges)
              option(
                s.miniChartChoice(minutes),
                _MiniSetting.chart,
                minutes,
                mini.chartMinutes == minutes,
              ),
            heading(s.miniProjectsShown),
            for (final count in MiniPreferences.projectCounts)
              option(
                s.miniProjectsChoice(count),
                _MiniSetting.projects,
                count,
                mini.projects == count,
              ),
          ],
        );
      },
    );
    if (!mounted || selection == null) return;
    final (setting, value) = selection;
    final prefs = c.preferences;
    await c.setPreferences(
      prefs.copyWith(
        mini: switch (setting) {
          _MiniSetting.refresh => prefs.mini.copyWith(seconds: value),
          _MiniSetting.chart => prefs.mini.copyWith(chartMinutes: value),
          _MiniSetting.projects => prefs.mini.copyWith(projects: value),
        },
      ),
    );
  }

  Widget _header(LensPalette p) {
    final s = context.strings;
    final now = c.clock().toLocal();
    final pinned = c.preferences.mini.pinned;
    final color = _hovered ? p.muted : p.faint.withValues(alpha: .64);
    final reduced = MediaQuery.disableAnimationsOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => unawaited(widget.window.startDragging()),
      child: SizedBox(
        height: 40,
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 8),
          child: Row(
            children: [
              const BrandMark(size: 22),
              const SizedBox(width: 5),
              Text(s.today, style: p.serif(15)),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  s.calendarDayWithWeekday(now.month, now.day, now.weekday),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: p.text(11.5, p.faint),
                ),
              ),
              LensIconButton(
                size: 'xs',
                icon: Icons.close_fullscreen,
                tooltip: s.miniPillEnter,
                color: color,
                onPressed: () => _miniPillAction(
                  () => widget.window.enterPill(MiniPill.widthFor(context, c)),
                ),
              ),
              AnimatedRotation(
                duration: reduced ? Duration.zero : LensTokens.hover,
                turns: pinned ? 0 : -.12,
                child: LensIconButton(
                  size: 'xs',
                  icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  tooltip: pinned ? s.miniUnpin : s.miniPin,
                  color: pinned ? p['clay-ink'] : color,
                  onPressed: () => unawaited(widget.window.togglePin()),
                ),
              ),
              LensIconButton(
                key: _settings,
                size: 'xs',
                icon: Icons.settings_outlined,
                tooltip: s.miniSettings,
                color: color,
                onPressed: () => unawaited(_openSettings()),
              ),
              LensIconButton(
                size: 'xs',
                icon: Icons.open_in_full,
                tooltip: s.miniExpand,
                color: color,
                onPressed: widget.onExpand,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _heroTotal(LensPalette p, StatsTotals? total) {
    final s = context.strings;
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(
                  begin: 0,
                  end: (total?.grossTokens ?? 0).toDouble(),
                ),
                duration: reduce ? Duration.zero : LensTokens.grow,
                curve: LensTokens.ease,
                builder: (context, n, _) => Text(
                  total == null ? '—' : _miniTokens(c, n.round()),
                  style: p.serif(36),
                ),
              ),
              const SizedBox(width: 5),
              Text(s.tokenUnit, style: p.text(11.5, p.faint)),
            ],
          ),
        ),
        if (total?.costMicros case final micros?)
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: micros.toDouble()),
            duration: reduce ? Duration.zero : LensTokens.grow,
            curve: LensTokens.ease,
            builder: (context, n, _) => Text(
              s.miniEstimate(_miniMoney(c.preferences, n.round())),
              style: p.text(12, p.secondary),
            ),
          )
        else if (total != null)
          Tooltip(
            message: s.unpriced,
            child: Text('—', style: p.text(12, p.faint)),
          ),
      ],
    );
  }

  Widget _hero(LensPalette p, StatsMiniUsage? usage) {
    final values = usage?.minutes ?? const <int>[];
    final observedAt = c.miniObservedAt;
    final lastMinute = observedAt == null ? null : _chartMinuteOf(observedAt);
    final s = context.strings;
    String tip(int index) => s.miniChartTip(
      _chartTime(_chartTimeAt(lastMinute!, values.length, index)),
      _miniTokens(c, values[index]),
      index == values.length - 1,
    );

    final total = _heroTotal(p, usage?.totals);
    final selected = _chartSelection;
    return SizedBox(
      height: 96,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 1, 16, 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: lastMinute == null || values.isEmpty
                  ? total
                  : LayoutBuilder(
                      builder: (context, constraints) => Row(
                        children: [
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: math.max(
                                0,
                                constraints.maxWidth -
                                    10 -
                                    _MiniUsageChart.minWidth,
                              ),
                            ),
                            child: total,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: _MiniUsageChart(
                                key: ValueKey((c, values.length)),
                                values: values,
                                lastMinute: lastMinute,
                                unitSystem: c.unitSystem,
                                tip: tip,
                                onSelectionChanged: (index) =>
                                    setState(() => _chartSelection = index),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            _MiniStatus(
              controller: c,
              selectedTip: lastMinute == null || selected == null
                  ? null
                  : tip(selected),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context), s = context.strings;
    final usage = _usage;
    final projects = usage?.projects ?? const <StatsMiniProject>[];
    final models = usage?.activeModels ?? const <StatsGroup>[];
    final requests = usage?.requests;
    final preference = c.preferences.mini.projects;
    return Material(
      color: p['surface-1'],
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Stack(
          fit: StackFit.expand,
          children: [
            MiniReveal(
              child: Column(
                children: [
                  _header(p),
                  _hero(p, usage),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, bounds) {
                        final layout = _OverviewLayout(
                          bounds.maxHeight - 44 - LensPalette.hairline(context),
                          preference: preference,
                          projects: projects.length,
                          models: models.length,
                        );
                        final caption = _requests
                            ? s.miniLatest(requests?.items.length ?? 0)
                            : projects.length > layout.projects
                            ? s.miniTopProjects(layout.projects)
                            : s.miniAllProjects;
                        return Column(
                          children: [
                            SizedBox(
                              height: 44,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  5,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      flex: 3,
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: LensSegmented(
                                          options: {
                                            'overview': s.overview,
                                            'requests': s.requests,
                                          },
                                          value: _requests
                                              ? 'requests'
                                              : 'overview',
                                          onChanged: (tab) => setState(
                                            () => _requests = tab == 'requests',
                                          ),
                                          label: s.miniWindow,
                                          slideOnHover: true,
                                          small: true,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        caption,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.right,
                                        style: p.text(11.5, p.faint),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Divider(
                              height: LensPalette.hairline(context),
                              thickness: LensPalette.hairline(context),
                              color: p['line'],
                              indent: 16,
                              endIndent: 16,
                            ),
                            Expanded(
                              child: _MiniTabContent(
                                key: ValueKey(_requests),
                                forward: _requests,
                                child: _requests
                                    ? _MiniRequestList(
                                        data: requests,
                                        onOpen: widget.onRequest,
                                        flashes: _requestFlashes,
                                        controller: c,
                                      )
                                    : _MiniOverview(
                                        layout: layout,
                                        projects: projects,
                                        models: models,
                                        onOpen: widget.onProject,
                                        flashes: _projectFlashes,
                                        controller: c,
                                      ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            _MiniResizeFeedback(
              hovered: _hovered,
              dimensions: widget.window.sizeWhileResizing,
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStatus extends StatefulWidget {
  const _MiniStatus({required this.controller, required this.selectedTip});
  final StatsController controller;
  final String? selectedTip;

  @override
  State<_MiniStatus> createState() => _MiniStatusState();
}

class _MiniStatusState extends State<_MiniStatus> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.controller.miniUpdatedAt != null && !widget.controller.busy) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller,
        s = context.strings,
        p = LensPalette.of(context);
    final selectedTip = widget.selectedTip;
    final running = selectedTip == null && c.busy;
    final failed = selectedTip == null && !running && c.miniSyncFailed;
    final color = selectedTip != null || running
        ? p['clay']
        : failed
        ? p['danger']
        : p['ok'];
    final updated = c.miniUpdatedAt;
    final label =
        selectedTip ??
        (running || (updated == null && !failed)
            ? s.syncing
            : failed
            ? s.miniSyncFailed
            : s.miniUpdated(
                math.max(0, c.clock().difference(updated!).inSeconds),
                c.preferences.mini.seconds,
              ));
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          if (running)
            LensLoop(
              duration: LensTokens.pulse + LensTokens.gentle,
              builder: (_, t) {
                return SyncDot(
                  color: color.withValues(
                    alpha: .72 + .28 * math.cos(t * math.pi * 2),
                  ),
                  revision: 0,
                );
              },
            )
          else
            SyncDot(
              color: color,
              revision: selectedTip != null || failed ? 0 : c.miniRevision,
            ),
          const SizedBox(width: 7),
          Expanded(
            child: ExcludeSemantics(
              excluding: selectedTip != null,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: p.text(
                  11,
                  selectedTip != null
                      ? p.secondary
                      : (failed ? color : p.muted),
                ),
              ),
            ),
          ),
          if (failed)
            LensTextLink(
              onTap: () => unawaited(
                c.syncErrorKind == StatsSyncErrorKind.status
                    ? c.retryStatus()
                    : c.sync(),
              ),
              label: s.retry,
            ),
        ],
      ),
    );
  }
}

String _miniTokens(StatsController c, int value) =>
    tokenCount(value, unitSystem: c.unitSystem);

String _miniMoney(UiPreferences preferences, int? micros) => micros == null
    ? '—'
    : usdCurrency(
        micros / 1000000,
        currency: preferences.currency,
        rate: rateFor(preferences.rates, preferences.currency),
      );
