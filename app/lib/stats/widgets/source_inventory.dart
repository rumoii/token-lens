import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';
import '../../stats_controller.dart';
import '../../stats_gateway.dart';
import '../logic/format.dart';
import '../logic/tools.dart';
import '../theme/palette.dart';
import 'primitives.dart';
import 'sources_parts.dart';

class SourceInventory extends StatefulWidget {
  const SourceInventory({
    super.key,
    required this.discovery,
    required this.sources,
    required this.month,
    required this.controller,
    required this.query,
    required this.onDetail,
    this.openLink,
  });

  final StatsDiscovery discovery;
  final List<StatsSource> sources;
  final Map<String?, int> month;
  final StatsController controller;
  final String query;
  final ValueChanged<Map<String, String>> onDetail;
  final Future<bool> Function(Uri)? openLink;

  @override
  State<SourceInventory> createState() => _SourceInventoryState();
}

class _SourceInventoryState extends State<SourceInventory> {
  String filter = 'all', search = '';
  final searchText = TextEditingController();
  bool missingExpanded = false;
  final expanded = <String>{};
  StatsController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    readFilter();
  }

  @override
  void didUpdateWidget(SourceInventory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) readFilter();
  }

  @override
  void dispose() {
    searchText.dispose();
    super.dispose();
  }

  void readFilter() {
    filter = Uri.splitQueryString(widget.query)['filter'] == 'hidden'
        ? 'hidden'
        : 'all';
  }

  String group(StatsDiscoveredTool tool) => switch (tool.status) {
    'found' => 'found',
    'missing' => 'missing',
    _ => 'issues',
  };

  String groupLabel(String group) => switch (group) {
    'found' => context.strings.inventoryFound,
    'issues' => context.strings.inventoryIssues,
    'missing' => context.strings.inventoryMissing,
    'hidden' => context.strings.inventoryHidden,
    _ => context.strings.all,
  };

  bool matches(StatsDiscoveredTool tool, String filter) => switch (filter) {
    'all' => true,
    'hidden' => c.isHidden(tool.source),
    _ => group(tool) == filter,
  };

  String statusLabel(String status, {int? files}) => switch (status) {
    'found' =>
      files == null
          ? context.strings.inventoryFound
          : context.strings.inventoryFilesFound(files),
    'permission_denied' => context.strings.inventoryDenied,
    'io_error' => context.strings.inventoryReadError,
    _ =>
      files == null
          ? context.strings.inventoryMissing
          : context.strings.inventoryPathMissing,
  };

  Widget badge(String label, String tone) => LensBadge(
    label,
    tone: switch (tone) {
      'found' => 'ok',
      'permission_denied' => 'warn',
      'io_error' => 'danger',
      _ => 'neutral',
    },
  );

  void feedback(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  Future<void> openDirectory(
    StatsLogDirectory dir,
    Future<bool> Function(Uri) open,
  ) async {
    try {
      if (await open(Uri.directory(dir.path))) return;
    } catch (_) {
      // The folder can disappear or lose access after discovery.
    }
    if (mounted) feedback(context.strings.couldNotOpenTheContainingFolder);
  }

  Widget actions(StatsLogDirectory? dir) {
    final open = widget.openLink;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LensIconButton(
          size: 'xs',
          tooltip: context.strings.inventoryOpen,
          icon: Icons.folder_open_outlined,
          onPressed: dir?.exists == true && open != null
              ? () => unawaited(openDirectory(dir!, open))
              : null,
        ),
        LensIconButton(
          size: 'xs',
          tooltip: context.strings.inventoryCopy,
          icon: Icons.copy_outlined,
          onPressed: dir == null
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: dir.path));
                  if (!mounted) return;
                  feedback(context.strings.inventoryCopied);
                },
        ),
      ],
    );
  }

  Widget path(String value) => _InventoryPath(value);

  Widget heading(String value) {
    final p = LensPalette.of(context);
    return Text(value, style: p.text(12, p.muted, FontWeight.w500));
  }

  Widget columns(
    Widget identity,
    Widget status,
    Widget folder,
    Widget files,
    Widget last,
    Widget actions,
    Widget toggle,
  ) => Row(
    children: [
      Expanded(flex: 20, child: identity),
      Expanded(flex: 17, child: status),
      Expanded(flex: 30, child: folder),
      Expanded(flex: 7, child: files),
      Expanded(flex: 15, child: last),
      SizedBox(width: 96, child: actions),
      SizedBox(width: 58, child: toggle),
    ],
  );

  Widget row(StatsDiscoveredTool tool, StatsSource? known, bool wide) {
    final p = LensPalette.of(context), s = context.strings;
    final id = tool.source;
    final hidden = c.isHidden(id), open = expanded.contains(id);
    final count = tool.directories.fold<int>(0, (n, dir) => n + dir.files);
    final primary =
        tool.directories.where((dir) => dir.status == 'found').firstOrNull ??
        tool.directories.firstOrNull;
    final tokens = widget.month[id] ?? 0;
    final identity = Row(
      children: [
        LensDisclosureArrow(expanded: open),
        const SizedBox(width: 5),
        ToolTile(id, size: 29),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                toolOf(id).name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: p.text(13, p.ink, FontWeight.w600),
              ),
              Text(
                s.inventoryMonth(
                  tokenCount(
                    tokens,
                    mode: c.preferences.tokenMode,
                    unitSystem: c.unitSystem,
                  ),
                ),
                style: p.text(11, p.muted),
              ),
            ],
          ),
        ),
      ],
    );
    final status = Wrap(
      spacing: 4,
      runSpacing: 3,
      children: [
        badge(statusLabel(tool.status), tool.status),
        if (hidden) badge(s.inventoryHidden, 'hidden'),
      ],
    );
    final switcher = tool.status == 'found' || (known?.records ?? 0) > 0
        ? Tooltip(
            message: s.inventoryShowInStats,
            child: LensSwitch(
              key: ValueKey('show-$id'),
              label: '${s.inventoryShowInStats} · ${toolOf(id).name}',
              value: !hidden,
              onChanged: (value) => unawaited(c.setToolVisible(id, value)),
            ),
          )
        : const SizedBox.shrink();
    final last = sourceRelativeTime(known?.lastObservedAt, c.clock(), s);
    final folder = Padding(
      padding: const EdgeInsets.only(right: 10),
      child: path(primary?.path ?? '—'),
    );
    final rowActions = actions(primary);
    void showUsage() => widget.onDetail({'tool': id, 'dim': 'model'});

    return Opacity(
      key: ValueKey('tool-$id'),
      opacity: hidden ? .62 : 1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LensDisclosure(
            expanded: open,
            showArrow: false,
            onPressed: () => setState(() {
              if (open) {
                expanded.remove(id);
              } else {
                expanded.add(id);
              }
            }),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 12 * c.preferences.spacing,
                vertical: 5 * c.preferences.spacing,
              ),
              child: wide
                  ? columns(
                      identity,
                      status,
                      folder,
                      Text(toDisplayNumber(count), style: p.text(12)),
                      Text(last, style: p.text(12, p.muted)),
                      rowActions,
                      switcher,
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(child: identity),
                            status,
                            switcher,
                          ],
                        ),
                        Row(
                          children: [
                            Expanded(child: folder),
                            rowActions,
                          ],
                        ),
                        Text(
                          '${s.inventoryFiles} ${toDisplayNumber(count)} · ${s.inventoryLastUsed} $last',
                          style: p.text(12, p.muted),
                        ),
                      ],
                    ),
            ),
          ),
          if (open)
            Container(
              color: p['surface-0'],
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 8,
                children: [
                  heading(s.inventoryLocations),
                  for (final dir in tool.directories)
                    Row(
                      children: [
                        Expanded(child: path(dir.path)),
                        const SizedBox(width: 6),
                        badge(
                          statusLabel(dir.status, files: dir.files),
                          dir.status,
                        ),
                        actions(dir),
                      ],
                    ),
                  if (tool.directories.any(
                    (dir) => dir.status == 'permission_denied',
                  ))
                    Text(
                      s.tokenLensOnlyReadsLogFilesCheck,
                      style: p.text(12, p['warn']),
                    ),
                  if (known != null)
                    SourcesToolCard(
                      item: known,
                      permissionDenied: tool.status == 'permission_denied',
                      monthTokens: tokens,
                      controller: c,
                      onDetail: showUsage,
                      showHeading: false,
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: LensTextLink(
                      label: s.inventoryViewUsage,
                      arrow: true,
                      onTap: showUsage,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings, p = LensPalette.of(context);
    final entries = widget.discovery.tools;
    final needle = search.trim().toLowerCase();
    final visible = entries.where(
      (t) =>
          matches(t, filter) &&
          (toolOf(t.source).name.toLowerCase().contains(needle) ||
              t.directories.any(
                (dir) => dir.path.toLowerCase().contains(needle),
              )),
    );
    final recorded = {for (final item in widget.sources) item.source: item};
    final sections = {
      for (final name in ['found', 'issues', 'missing'])
        name: visible.where((tool) => group(tool) == name).toList()
          ..sort((a, b) {
            final usage = (widget.month[b.source] ?? 0).compareTo(
              widget.month[a.source] ?? 0,
            );
            return usage != 0
                ? usage
                : toolOf(a.source).name.compareTo(toolOf(b.source).name);
          }),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final name in ['all', 'found', 'issues', 'hidden', 'missing'])
              LensChip(
                key: ValueKey('source-filter-$name'),
                label: groupLabel(name),
                count: entries.where((tool) => matches(tool, name)).length,
                selected: filter == name,
                onPressed: () => setState(() => filter = name),
              ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 360,
            child: LensInput(
              controller: searchText,
              search: true,
              hint: s.inventorySearch,
              onChanged: (value) => setState(() => search = value),
            ),
          ),
        ),
        Text(s.inventoryVisibility, style: p.text(12, p.secondary)),
        LayoutBuilder(
          builder: (context, bounds) {
            final wide = bounds.maxWidth >= 730;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 10,
              children: [
                if (wide)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: columns(
                      heading(s.tool),
                      heading(s.status),
                      heading(s.inventoryFolder),
                      heading(s.inventoryFiles),
                      heading(s.inventoryLastUsed),
                      const SizedBox.shrink(),
                      Center(child: heading(s.inventoryShow)),
                    ),
                  ),
                for (final section in sections.entries)
                  if (section.value.isNotEmpty ||
                      filter == 'all' && needle.isEmpty)
                    LensCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (section.key == 'missing')
                            LensDisclosure(
                              key: ValueKey('source-group-${section.key}'),
                              expanded:
                                  missingExpanded ||
                                  filter != 'all' ||
                                  needle.isNotEmpty,
                              onPressed: () => setState(
                                () => missingExpanded = !missingExpanded,
                              ),
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                              child: Text(
                                '${groupLabel(section.key)}  ${section.value.length}',
                                style: p.text(13, p.secondary, FontWeight.w600),
                              ),
                            )
                          else
                            Padding(
                              key: ValueKey('source-group-${section.key}'),
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                              child: Text(
                                '${groupLabel(section.key)}  ${section.value.length}',
                                style: p.text(13, p.secondary, FontWeight.w600),
                              ),
                            ),
                          if (section.key != 'missing' ||
                              missingExpanded ||
                              filter != 'all' ||
                              needle.isNotEmpty)
                            for (final tool in section.value) ...[
                              Divider(height: 1, color: p['line']),
                              row(
                                tool,
                                recorded[tool.source] ?? tool.profile,
                                wide,
                              ),
                            ],
                        ],
                      ),
                    ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _InventoryPath extends StatelessWidget {
  const _InventoryPath(this.value);
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final style = p
        .text(12, p.secondary)
        .copyWith(
          fontFamily: LensPalette.monoFonts.first,
          fontFamilyFallback: LensPalette.monoFonts.skip(1).toList(),
        );
    return Tooltip(
      message: value,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final direction = Directionality.of(context);
          final scaler = MediaQuery.textScalerOf(context);
          final painter = TextPainter(
            textDirection: direction,
            textScaler: scaler,
            maxLines: 1,
          );
          bool fits(String text) {
            painter.text = TextSpan(text: text, style: style);
            painter.layout();
            return painter.width <= constraints.maxWidth;
          }

          var result = value;
          if (!fits(value)) {
            final units = value.characters.toList();
            var low = 0, high = units.length;
            String shorten(int length) {
              final front = (length + 1) ~/ 2;
              return '${units.take(front).join()}…'
                  '${units.skip(units.length - (length - front)).join()}';
            }

            while (low < high) {
              final middle = (low + high + 1) ~/ 2;
              if (fits(shorten(middle))) {
                low = middle;
              } else {
                high = middle - 1;
              }
            }
            result = shorten(low);
          }
          painter.dispose();
          return RichText(
            text: TextSpan(text: result, style: style),
            textDirection: direction,
            textScaler: scaler,
            softWrap: false,
            maxLines: 1,
            overflow: TextOverflow.clip,
          );
        },
      ),
    );
  }
}
