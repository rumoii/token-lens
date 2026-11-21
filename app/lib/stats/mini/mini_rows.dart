part of 'mini_panel.dart';

class _OverviewLayout {
  _OverviewLayout(
    double height, {
    required int preference,
    required int projects,
    required int models,
  }) : fit = preference == -1 {
    final available = math.max(0, height - padding - 2 * sectionHeight);
    if (fit) {
      final budget = math.max(
        0,
        (available - projectHeight * math.min(projects, 2)) ~/ modelHeight,
      );
      final modelSlots = math.max(1, budget);
      this.models = models <= modelSlots ? models : modelSlots - 1;
      final modelRows = models == 0
          ? 1
          : this.models + (models > this.models ? 1 : 0);
      final slots = math.max(
        0,
        (available - modelRows * modelHeight) ~/ projectHeight,
      );
      this.projects = projects <= slots ? projects : math.max(0, slots - 1);
    } else {
      this.projects = preference == 0
          ? projects
          : math.min(projects, preference);
      this.models = models;
    }
  }

  static const sectionHeight = 30.0;
  static const projectHeight = 36.0;
  static const modelHeight = 32.0;
  static const padding = 18.0;
  final bool fit;
  late final int projects, models;
}

class _MiniOverview extends StatelessWidget {
  const _MiniOverview({
    required this.layout,
    required this.projects,
    required this.models,
    required this.onOpen,
    required this.flashes,
    required this.controller,
  });

  final _OverviewLayout layout;
  final List<StatsMiniProject> projects;
  final List<StatsGroup> models;
  final ValueChanged<String?> onOpen;
  final Map<String?, int> flashes;
  final StatsController controller;

  @override
  Widget build(BuildContext context) {
    final s = context.strings, p = LensPalette.of(context);
    final visible = projects.take(layout.projects).toList();
    final rest = projects.skip(layout.projects);
    final top = projects.firstOrNull?.grossTokens ?? 0;
    final colors = assignToolColors([
      for (final project in projects)
        for (final tool in project.tools) (tool.source, tool.grossTokens),
    ], p);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final children = [
      _MiniSection(s.miniProjects),
      if (projects.isEmpty)
        _MiniEmpty(s.miniNoUsage, height: _OverviewLayout.projectHeight)
      else
        SizedBox(
          height: visible.length * _OverviewLayout.projectHeight,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              for (final (index, project) in visible.indexed)
                AnimatedPositioned(
                  key: ValueKey(project.key),
                  top: index * _OverviewLayout.projectHeight,
                  left: 0,
                  right: 0,
                  height: _OverviewLayout.projectHeight,
                  duration: reduced ? Duration.zero : LensTokens.gentle,
                  curve: LensTokens.gentleEase,
                  child: MiniProjectRow(
                    project: project,
                    colors: colors,
                    maximum: top,
                    tokens: (value) => _miniTokens(controller, value),
                    amount: _miniMoney(
                      controller.preferences,
                      project.costMicros,
                    ),
                    onOpen: () => onOpen(project.key),
                    flash: flashes[project.key],
                  ),
                ),
            ],
          ),
        ),
      if (rest.isNotEmpty) _MoreProjects(rest, controller),
      _MiniSection(s.miniActiveModels),
      if (models.isEmpty)
        _MiniEmpty(s.miniNoModels, height: _OverviewLayout.modelHeight)
      else ...[
        for (final model in models.take(layout.models))
          _ActiveModel(model, controller),
        if (models.length > layout.models)
          Tooltip(
            message: models
                .skip(layout.models)
                .map((m) {
                  return '${toolOf(m.source ?? '').name} · ${m.key ?? s.unknownModel}';
                })
                .join('\n'),
            child: _MiniEmpty(
              s.miniMoreModels(models.length - layout.models),
              height: _OverviewLayout.modelHeight,
            ),
          ),
      ],
    ];
    const padding = EdgeInsets.fromLTRB(8, 4, 8, 14);
    if (layout.fit) {
      return Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
    }
    return _MiniScroll(
      builder: (controller) => ListView(
        controller: controller,
        padding: padding,
        children: children,
      ),
    );
  }
}

class _MiniSection extends StatelessWidget {
  const _MiniSection(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    return SizedBox(
      height: _OverviewLayout.sectionHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            style: p.text(11.5, p.muted, FontWeight.w500),
            maxLines: 1,
          ),
        ),
      ),
    );
  }
}

class _MiniEmpty extends StatelessWidget {
  const _MiniEmpty(this.label, {this.height = 92});
  final String label;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Center(
      child: Text(
        label,
        style: LensPalette.of(context).text(12, LensPalette.of(context).muted),
      ),
    ),
  );
}

class MiniProjectRow extends StatelessWidget {
  const MiniProjectRow({
    super.key,
    required this.project,
    required this.colors,
    required this.maximum,
    required this.tokens,
    required this.amount,
    required this.onOpen,
    this.flash,
  });

  final StatsMiniProject project;
  final Map<String, Color> colors;
  final int maximum;
  final String Function(int) tokens;
  final String amount;
  final VoidCallback onOpen;
  final int? flash;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context), s = context.strings;
    final name = projectName(project.key) ?? s.noProjectLogged;
    return _MiniRow(
      onTap: onOpen,
      tooltip: project.key,
      flash: flash,
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: p.text(
                      13,
                      project.key == null ? p.muted : p.ink,
                      FontWeight.w500,
                    ),
                  ),
                ),
                if (project.tools.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  _MiniToolStack(project.tools),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          _ProjectBar(tools: project.tools, colors: colors, maximum: maximum),
          const SizedBox(width: 7),
          _MiniProjectTotals(tokens(project.grossTokens), amount),
        ],
      ),
    );
  }
}

class _MiniToolStack extends StatelessWidget {
  const _MiniToolStack(this.tools);
  final List<StatsMiniTool> tools;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final count = math.min(3, tools.length);
    const size = 14.0;
    const step = size - 4;
    return Tooltip(
      message: tools.map((t) => toolOf(t.source).name).join(' · '),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size + step * (count - 1),
            height: size,
            child: Stack(
              children: [
                for (var i = 0; i < count; i++)
                  Positioned(
                    left: i * step,
                    child: ToolTile(
                      tools[i].source,
                      size: size,
                      accent: p['surface-1'],
                    ),
                  ),
              ],
            ),
          ),
          if (tools.length > 3)
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Text('+${tools.length - 3}', style: p.text(10, p.muted)),
            ),
        ],
      ),
    );
  }
}

class _MoreProjects extends StatelessWidget {
  const _MoreProjects(this.projects, this.controller);
  final Iterable<StatsMiniProject> projects;
  final StatsController controller;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    var total = 0;
    int? cost;
    for (final project in projects) {
      total += project.grossTokens;
      if (project.costMicros case final micros?) cost = (cost ?? 0) + micros;
    }
    return SizedBox(
      height: _OverviewLayout.projectHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                context.strings.miniMoreProjects(projects.length),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: p.text(12, p.muted),
              ),
            ),
            _MiniProjectTotals(
              _miniTokens(controller, total),
              _miniMoney(controller.preferences, cost),
              isSummary: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniProjectTotals extends StatelessWidget {
  const _MiniProjectTotals(this.tokens, this.amount, {this.isSummary = false});

  final String tokens;
  final String amount;
  final bool isSummary;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    Widget cell(double width, String value, TextStyle style) => SizedBox(
      width: width,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Text(value, style: style, maxLines: 1),
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        cell(46, tokens, isSummary ? p.text(12, p.secondary) : p.text(12.5)),
        const SizedBox(width: 8),
        cell(38, amount, p.text(11.5, p.faint)),
      ],
    );
  }
}

class _ActiveModel extends StatelessWidget {
  const _ActiveModel(this.model, this.controller);
  final StatsGroup model;
  final StatsController controller;

  @override
  Widget build(BuildContext context) {
    final s = context.strings, p = LensPalette.of(context);
    final source = model.source ?? '';
    final tool = toolOf(source).name;
    final timing = model.modelTiming;
    final speeds = [
      ...?timing?.speed,
      ...?timing?.turn?.speed,
    ].where((t) => t.sampleCount > 0);
    final speed =
        speeds.where((t) => t.method == 'client_reported').firstOrNull ??
        speeds.firstOrNull;
    final averages = [
      ...?timing?.throughput,
      ...?timing?.turn?.throughput,
    ].where((t) => t.sampleCount > 0);
    final average =
        averages.where((t) => t.method == 'client_reported').firstOrNull ??
        averages.firstOrNull;
    final noTiming = speed == null && average == null;
    final text = speed != null
        ? s.about0TokenS(speed.tokensPerSecond.toStringAsFixed(1))
        : average != null
        ? s.miniApproxSpeed(average.tokensPerSecond.toStringAsFixed(1))
        : '${_miniTokens(controller, model.grossTokens)} ${s.tokenUnit}';
    final name = model.key ?? s.unknownModel;
    final value = Text(
      text,
      style: p
          .text(12, p.secondary)
          .copyWith(
            decoration: noTiming ? TextDecoration.underline : null,
            decorationStyle: noTiming ? TextDecorationStyle.dashed : null,
            decorationColor: p.faint,
          ),
    );
    return SizedBox(
      height: _OverviewLayout.modelHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Tooltip(message: tool, child: ToolTile(source, size: 16)),
            const SizedBox(width: 7),
            Expanded(
              child: Tooltip(
                message: name,
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: p.text(12.5, p.secondary),
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (noTiming)
              Tooltip(message: s.miniUntimedModel(tool), child: value)
            else if (speed == null)
              Tooltip(message: s.averageSpeedIncludesWait(tool), child: value)
            else
              value,
          ],
        ),
      ),
    );
  }
}

class _MiniRequestList extends StatelessWidget {
  const _MiniRequestList({
    required this.data,
    required this.onOpen,
    required this.flashes,
    required this.controller,
  });

  final StatsRequests? data;
  final ValueChanged<StatsRequest> onOpen;
  final Map<String, int> flashes;
  final StatsController controller;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final requests = data?.items ?? [];
    if (requests.isEmpty) return _MiniEmpty(s.miniNoRequests);
    int? lastHour;
    return _MiniScroll(
      builder: (scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(8, 3, 8, 12),
        children: [
          for (final request in requests) ...[
            if (DateTime.tryParse(request.observedAt)?.toLocal().hour
                case final hour? when hour != lastHour)
              _MiniSection(s.miniHour(lastHour = hour)),
            _MiniRequestRow(
              key: ValueKey(request.id),
              request: request,
              slow: data?.slow,
              onOpen: request.sessionId == null ? null : () => onOpen(request),
              flash: flashes[request.id],
              controller: controller,
            ),
          ],
        ],
      ),
    );
  }
}

class _MiniRequestRow extends StatelessWidget {
  const _MiniRequestRow({
    super.key,
    required this.request,
    required this.slow,
    required this.onOpen,
    required this.flash,
    required this.controller,
  });

  final StatsRequest request;
  final StatsRequestSlow? slow;
  final VoidCallback? onOpen;
  final int? flash;
  final StatsController controller;

  @override
  Widget build(BuildContext context) {
    final s = context.strings, p = LensPalette.of(context);
    final r = request;
    final name = r.model ?? s.unknownModel;
    final project = projectName(r.projectKey) ?? s.noProjectLogged;
    final output = r.outputTokens;
    return _MiniRow(
      onTap: onOpen,
      tooltip: onOpen == null ? s.theLogHasNoSessionIdFor : null,
      flash: flash,
      slideIn: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          children: [
            Row(
              children: [
                Tooltip(
                  message: toolOf(r.source).name,
                  child: ToolTile(r.source, size: 16),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Tooltip(
                    message: name,
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: p.text(12.5, p.ink, FontWeight.w500),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  s.miniOutput(
                    output == null ? '—' : _miniTokens(controller, output),
                  ),
                  style: p.text(12, p.secondary),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 1),
              child: Row(
                children: [
                  Flexible(
                    child: Tooltip(
                      message: r.projectKey ?? project,
                      child: Text(
                        project,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: p.text(11, p.muted),
                      ),
                    ),
                  ),
                  Text(
                    ' · ${usageTime(r.observedAt)}',
                    style: p.text(11, p.faint),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    flex: 4,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Row(
                          key: const Key('mini-request-metrics'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            requestMetric(
                              context,
                              r,
                              slow,
                              ttft: false,
                              mini: true,
                            ),
                            Text(' · ', style: p.text(11, p.faint)),
                            requestMetric(
                              context,
                              r,
                              slow,
                              ttft: true,
                              mini: true,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniRow extends StatelessWidget {
  const _MiniRow({
    required this.child,
    this.onTap,
    this.tooltip,
    this.flash,
    this.slideIn = false,
  });
  final Widget child;
  final VoidCallback? onTap;
  final String? tooltip;
  final int? flash;
  final bool slideIn;

  @override
  Widget build(BuildContext context) {
    final radius = LensTokens.radii['lg']!;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: child,
    );
    final button = onTap == null
        ? content
        : LensFocusOutline(
            radius: radius,
            inset: true,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(radius),
              child: content,
            ),
          );
    final row = tooltip == null
        ? button
        : Tooltip(message: tooltip, child: button);
    return _MiniFlash(revision: flash, slideIn: slideIn, child: row);
  }
}
