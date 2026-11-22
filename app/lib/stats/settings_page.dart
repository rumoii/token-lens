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
import 'logic/pricing_display.dart';
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
  final _networkCard = GlobalKey();
  final _pricingCard = GlobalKey();
  late final pricing = LensResource<StatsPricing>(changed);
  late final usage = LensResource<StatsBreakdown>(changed);
  late final health = LensResource<StatsHealth>(changed);
  bool aboutOpen = false;
  bool exporting = false;
  String? exportPath;
  String Function(AppStrings)? exportError;
  Object? pricingUpdateError;
  bool get revealMissing =>
      Uri.splitQueryString(widget.query)['prices'] == 'missing';
  GlobalKey get networkCard => widget.updateCardKey ?? _networkCard;

  void _reveal(GlobalKey key) {
    if (key.currentContext case final target?) {
      unawaited(Scrollable.ensureVisible(target, alignment: .05));
    }
  }

  void _scheduleReveal() {
    if (!revealMissing) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && revealMissing) _reveal(_pricingCard);
    });
  }

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
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(StatsSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.removeListener(controllerChanged);
      widget.controller.addListener(controllerChanged);
      read();
    }
    if (widget.query != oldWidget.query) _scheduleReveal();
  }

  @override
  void dispose() {
    widget.controller.removeListener(controllerChanged);
    pricing.dispose();
    usage.dispose();
    health.dispose();
    super.dispose();
  }

  Future<void> _updatePricing(Future<void> Function() action) async {
    setState(() => pricingUpdateError = null);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => pricingUpdateError = error);
    }
  }

  Widget _pricingOnline() {
    final controller = widget.controller;
    final updates = controller.pricingUpdates, prefs = controller.preferences;
    final p = LensPalette.of(context), s = context.strings;
    final date = pricingDate(pricing.data?.publishedAt, s);
    final builtin = pricingDate(pricing.data?.builtinPublishedAt, s);
    final failed = switch (prefs.pricingLastKind) {
      'offline' => s.pricingOffline,
      'limited' => s.pricingLimited,
      'invalid' => s.pricingInvalid,
      _ => null,
    };
    final checking = updates.checking || updates.changingAutomatic;
    final note = prefs.pricingUpdatedNote;
    final checked = prefs.pricingCheckedMs;
    final status = checking
        ? s.pricingChecking
        : !prefs.autoUpdatePricing
        ? s.pricingDisabled(builtin)
        : failed ??
              (note == null
                  ? s.pricingUsingDate(date)
                  : note.newlyPriced == 0
                  ? s.pricingUpdatedNoNew(pricingDate(note.publishedAt, s))
                  : s.pricingUpdated(
                      pricingDate(note.publishedAt, s),
                      recordText(note.newlyPriced),
                    ));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LensSwitch(
          label: s.autoUpdatePricingLabel,
          value: prefs.autoUpdatePricing,
          onChanged: updates.changingAutomatic
              ? null
              : (value) => unawaited(
                  _updatePricing(() => updates.setAutomatic(value)),
                ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.autoUpdatePricingLabel,
                  style: p.text(14, null, FontWeight.w500),
                ),
                Text(s.autoUpdatePricingHelp, style: p.text(12.5, p.muted)),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Semantics(
            liveRegion: true,
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!checking && prefs.autoUpdatePricing && note != null)
                  Icon(Icons.check, size: 14, color: p['ok']),
                Text(
                  status,
                  style: p.text(
                    12.5,
                    checking || !prefs.autoUpdatePricing
                        ? p.muted
                        : failed != null
                        ? p['danger']
                        : note != null
                        ? p['ok']
                        : p.secondary,
                  ),
                ),
                if (!checking && prefs.autoUpdatePricing && failed != null)
                  Text(s.pricingStillUsing(date), style: p.text(12.5, p.muted)),
                if (!checking &&
                    prefs.autoUpdatePricing &&
                    failed == null &&
                    note == null &&
                    checked != null)
                  Text(
                    '· ${s.pricingCheckedAt(updateAttemptTime(checked, controller.clock(), s))}',
                    style: p.text(12.5, p.muted),
                  ),
                if (prefs.autoUpdatePricing && (note == null || checking))
                  LensTextLink(
                    label: failed == null ? s.pricingUpdateNow : s.retry,
                    tone: 'clay',
                    onTap: checking
                        ? null
                        : () => unawaited(_updatePricing(updates.check)),
                  ),
                if (pricingUpdateError case final error?)
                  Text(
                    s.requestFailed0(error),
                    style: p.text(12.5, p['danger']),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _aboutPrice() {
    final data = pricing.data;
    if (data == null) return '—';
    final s = context.strings;
    if (data.publishedAt == null) return s.builtInVersion(data.priceVersion);
    final version = data.priceVersion.length > 8
        ? data.priceVersion.substring(0, 8)
        : data.priceVersion;
    final date = pricingDate(data.publishedAt, s);
    return data.downloaded
        ? s.pricingAboutOnline(
            date,
            version,
            pricingDate(data.builtinPublishedAt, s),
          )
        : s.pricingAboutBuiltin(date, version);
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
          key: networkCard,
          controller: widget.controller.updates,
          openLink: widget.openLink,
          networkHeader: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.strings.networkAndUpdates,
                style: p.text(15, null, FontWeight.w600),
              ),
              LensSwitch(
                value: widget.controller.preferences.newsEnabled,
                onChanged: (enabled) => unawaited(
                  widget.controller.setPreferences(
                    widget.controller.preferences.copyWith(
                      newsEnabled: enabled,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.strings.aiNews,
                        style: p.text(14, null, FontWeight.w500),
                      ),
                      Text(
                        context.strings.newsPreferenceHint,
                        style: p.text(12.5, p.muted),
                      ),
                    ],
                  ),
                ),
              ),
              _pricingOnline(),
            ],
          ),
        ),
        gap(),
        LensCard(
          key: _pricingCard,
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
                    if (pricing.data case final data?)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              context.strings.pricingCatalogRow(
                                pricingDate(data.publishedAt, context.strings),
                                data.downloaded
                                    ? context.strings.pricingCatalogOnline
                                    : context.strings.pricingCatalogBuiltin,
                              ),
                              style: p.text(12.5, p.secondary),
                            ),
                            if (data.counts.manual > 0)
                              Text(
                                '· ${context.strings.pricingCatalogManual(recordText(data.counts.manual))}',
                                style: p.text(12.5, p.secondary),
                              ),
                            LensTextLink(
                              label: context.strings.pricingOnlineSettings,
                              tone: 'clay',
                              onTap: () => _reveal(networkCard),
                            ),
                          ],
                        ),
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
                      controller: widget.controller,
                      expandFirst: revealMissing,
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
                    LensButton(
                      onPressed: exporting ? null : exportDiagnostics,
                      label: exporting
                          ? context.strings.exporting
                          : context.strings.exportDiagnostics,
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
                      LensButton(
                        onPressed: openExportFolder,
                        label: context.strings.openContainingFolder,
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
              LensDisclosure(
                expanded: aboutOpen,
                onPressed: () => setState(() => aboutOpen = !aboutOpen),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                child: Text(
                  context.strings.aboutThisInstallationOfTokenLens,
                  style: p.text(13.5, p.secondary),
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
                          (context.strings.pricingVersion, _aboutPrice()),
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
