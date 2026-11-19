import '../l10n/app_strings.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../stats_controller.dart';
import '../stats_gateway.dart';
import 'theme/palette.dart';
import 'widgets/primitives.dart';
import 'widgets/resource.dart';
import 'widgets/settings_display.dart';
import 'widgets/settings_prices.dart';
import '../update/update_widgets.dart';

class StatsSettingsPage extends StatefulWidget {
  const StatsSettingsPage({
    super.key,
    required this.controller,
    this.query = '',
    this.openLink,
    this.downloadsDirectory,
    this.updateCardKey,
  });
  final StatsController controller;
  final String query;
  final Future<bool> Function(Uri)? openLink;
  final Future<Directory?> Function()? downloadsDirectory;
  final GlobalKey? updateCardKey;

  @override
  State<StatsSettingsPage> createState() => _StatsSettingsPageState();
}

class _StatsSettingsPageState extends State<StatsSettingsPage> {
  late final pricing = LensResource<StatsPricing>(changed);
  late final usage = LensResource<StatsBreakdown>(changed);
  late final health = LensResource<StatsHealth>(changed);
  bool aboutOpen = false;
  bool exporting = false;
  String? exportPath;
  String Function(AppStrings)? exportError;

  Future<void> exportDiagnostics() async {
    if (exporting) return;
    setState(() {
      exporting = true;
      exportPath = null;
      exportError = null;
    });
    final gateway = widget.controller.gateway;
    try {
      Directory? downloads;
      try {
        downloads =
            await (widget.downloadsDirectory ?? getDownloadsDirectory)();
      } catch (_) {
        /* Fall back to the app data directory. */
      }
      final directory =
          downloads?.path ??
          '${(await gateway.health()).dataDir}${Platform.pathSeparator}exports';
      final path = await gateway.exportDiagnostics(directory);
      if (mounted) setState(() => exportPath = path);
    } catch (error, stack) {
      if (mounted) {
        setState(
          () =>
              exportError = (strings) => strings.diagnosticsExportFailed(error),
        );
      }
      try {
        await gateway.logError(
          error.runtimeType.toString(),
          error.toString(),
          stack.toString(),
        );
      } catch (_) {
        /* Logging cannot fail the export UI. */
      }
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  Future<void> openExportFolder() async {
    final path = exportPath;
    if (path == null) return;
    final unavailable = StateError(
      chineseStrings.couldNotOpenTheContainingFolder,
    );
    try {
      final opened = await widget.openLink?.call(
        Uri.directory(File(path).parent.path),
      );
      if (opened != true) throw unavailable;
    } catch (error, stack) {
      if (mounted) {
        setState(() {
          exportError = (strings) => strings.exportFolderOpenFailed(
            identical(error, unavailable)
                ? StateError(strings.couldNotOpenTheContainingFolder)
                : error,
          );
        });
      }
      try {
        await widget.controller.gateway.logError(
          error.runtimeType.toString(),
          error.toString(),
          stack.toString(),
        );
      } catch (_) {
        /* Best effort. */
      }
    }
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void read() {
    final c = widget.controller,
        identity = (widget.controller.gateway, widget.controller.ledgerVersion);
    pricing.read(identity, c.gateway.pricing);
    usage.read(
      identity,
      () => c.gateway.breakdown('source_model', const StatsFilter()),
    );
    health.read(c.gateway, c.health);
  }

  void controllerChanged() {
    read();
    changed();
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(controllerChanged);
    read();
  }

  @override
  void didUpdateWidget(StatsSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.removeListener(controllerChanged);
      widget.controller.addListener(controllerChanged);
      read();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(controllerChanged);
    pricing.dispose();
    usage.dispose();
    health.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 768;
    Widget gap() => SizedBox(height: narrow ? 12 : 16);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.strings.pricingSettings,
          style: p
              .serif(narrow ? 24 : 28, weight: FontWeight.w500)
              .copyWith(height: 1.25, letterSpacing: -(narrow ? 24 : 28) * .01),
        ),
        const SizedBox(height: 4),
        Text(
          context.strings.displayPreferencesAndHowCostsAreCalculated,
          style: p.text(14, p.secondary),
        ),
        gap(),
        SettingsDisplay(controller: widget.controller),
        gap(),
        SettingsUpdate(
          key: widget.updateCardKey,
          controller: widget.controller.updates,
          openLink: widget.openLink,
          networkHeader: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.strings.networkAndUpdates,
                style: p.text(15, null, FontWeight.w600),
              ),
              Material(
                type: MaterialType.transparency,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    context.strings.aiNews,
                    style: p.text(14, null, FontWeight.w500),
                  ),
                  subtitle: Text(
                    context.strings.newsPreferenceHint,
                    style: p.text(12.5, p.muted),
                  ),
                  value: widget.controller.preferences.newsEnabled,
                  onChanged: (enabled) => unawaited(
                    widget.controller.setPreferences(
                      widget.controller.preferences.copyWith(
                        newsEnabled: enabled,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        gap(),
        LensCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.strings.pricing,
                      style: p.text(15, null, FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.strings.costsAreEstimatesAtEachModelS3,
                      style: p.text(12.5, p.muted),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
                child: ResourceBlock(
                  resource: usage,
                  rows: 1,
                  builder: (_) => ResourceBlock(
                    resource: pricing,
                    rows: 5,
                    builder: (data) => SettingsPrices(
                      pricing: data!,
                      usage: usage.data,
                      preferences: widget.controller.preferences,
                      openLink: widget.openLink,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        gap(),
        LensCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.strings.diagnosticsAbout,
                      style: p.text(15, null, FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.strings.ifUsageLooksWrongSyncFailsOr,
                      style: p.text(12.5, p.muted),
                    ),
                    const SizedBox(height: 14),
                    LensFocusOutline(
                      child: OutlinedButton(
                        onPressed: exporting ? null : exportDiagnostics,
                        child: Text(
                          exporting
                              ? context.strings.exporting
                              : context.strings.exportDiagnostics,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      context.strings.includesAppAndSystemVersionsResultsAnd,
                      style: p.text(12, p.muted),
                    ),
                    if (exportPath != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: SelectableText(
                          context.strings.savedTo0(exportPath),
                          style: p.text(13),
                        ),
                      ),
                      const SizedBox(height: 8),
                      LensFocusOutline(
                        child: OutlinedButton(
                          onPressed: openExportFolder,
                          child: Text(context.strings.openContainingFolder),
                        ),
                      ),
                    ],
                    if (exportError != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: SelectableText(
                          exportError!(context.strings),
                          style: p.text(13),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Semantics(
                expanded: aboutOpen,
                button: true,
                child: LensFocusOutline(
                  child: InkWell(
                    onTap: () => setState(() => aboutOpen = !aboutOpen),
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      child: Row(
                        children: [
                          AnimatedRotation(
                            turns: aboutOpen ? .25 : 0,
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 140),
                            child: Icon(
                              Icons.chevron_right,
                              size: 14,
                              color: p.secondary,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              context.strings.aboutThisInstallationOfTokenLens,
                              style: p.text(13.5, p.secondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (aboutOpen)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                  child: ResourceBlock(
                    resource: health,
                    rows: 2,
                    builder: (data) => Table(
                      columnWidths: const {
                        0: IntrinsicColumnWidth(),
                        1: FlexColumnWidth(),
                      },
                      children: [
                        for (final item in [
                          (context.strings.version, data?.version ?? '—'),
                          (context.strings.dataDirectory, data?.dataDir ?? '—'),
                          (context.strings.ledgerPath, data?.ledgerPath ?? '—'),
                          (
                            context.strings.schemaVersion,
                            data?.schemaVersion.toString() ?? '—',
                          ),
                          (
                            context.strings.pricingVersion,
                            context.strings.builtInVersion(
                              pricing.data?.priceVersion ?? '—',
                            ),
                          ),
                        ])
                          TableRow(
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(
                                  right: 14,
                                  bottom: 4,
                                ),
                                child: Text(
                                  item.$1,
                                  style: p.text(13, p.muted),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: SelectableText(
                                  item.$2,
                                  style: p
                                      .text(13)
                                      .copyWith(
                                        fontFamily: LensPalette.monoFonts.first,
                                        fontFamilyFallback: LensPalette
                                            .monoFonts
                                            .skip(1)
                                            .toList(),
                                      ),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
