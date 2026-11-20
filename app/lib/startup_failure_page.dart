import 'dart:io';

import 'package:flutter/material.dart';

import 'l10n/app_strings.dart';
import 'startup_failure.dart';
import 'stats/theme/palette.dart';
import 'stats/widgets/primitives.dart';

class StartupFailurePage extends StatelessWidget {
  const StartupFailurePage({super.key, required this.card});

  final StartupFailureCard card;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: LensPalette.of(context)['surface-1'],
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: card,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class StartupFailureCard extends StatefulWidget {
  const StartupFailureCard({
    super.key,
    required this.failure,
    required this.dataDir,
    required this.version,
    required this.openLink,
    this.exportDiagnostics,
    this.logDirectory,
    this.appDirectory,
    this.onClose,
    this.newsEnabled = false,
  });

  final StartupFailure failure;
  final String? dataDir, logDirectory, appDirectory;
  final String version;
  final Future<bool> Function(Uri) openLink;
  final Future<String> Function()? exportDiagnostics;
  final VoidCallback? onClose;
  final bool newsEnabled;

  @override
  State<StartupFailureCard> createState() => _StartupFailureCardState();
}

class _StartupFailureCardState extends State<StartupFailureCard> {
  bool _details = false, _exporting = false;
  String? _exportPath;
  Object? _exportError;
  String Function(AppStrings)? _folderError;

  Future<void> _export() async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _exportPath = null;
      _exportError = null;
      _folderError = null;
    });
    try {
      final path = await widget.exportDiagnostics!();
      if (mounted) setState(() => _exportPath = path);
    } catch (error) {
      if (mounted) setState(() => _exportError = error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _openFolder(String directory) async {
    try {
      final opened = await widget.openLink(Uri.directory(directory));
      if (!mounted) return;
      setState(() {
        _folderError = opened
            ? null
            : (strings) => strings.exportFolderOpenFailed(
                StateError(strings.couldNotOpenTheContainingFolder),
              );
      });
    } catch (error) {
      if (mounted) {
        setState(() => _folderError = (s) => s.exportFolderOpenFailed(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context), s = context.strings;
    final code = widget.failure.code;
    final copy = s.startupFailureCopy(widget.failure);
    final (icon, fill, color) = switch (code) {
      StartupErrorCode.alreadyRunning => (
        Icons.desktop_windows_outlined,
        p['fill-active'],
        p.secondary,
      ),
      StartupErrorCode.appFilesMissing => (
        Icons.insert_drive_file_outlined,
        p.dangerWash,
        p['danger'],
      ),
      StartupErrorCode.dataDirDenied => (
        Icons.lock_outline,
        p.warnWash,
        p['warn'],
      ),
      StartupErrorCode.diskFull => (
        Icons.storage_outlined,
        p.warnWash,
        p['warn'],
      ),
      StartupErrorCode.ledgerCorrupt => (
        Icons.warning_amber_rounded,
        p.dangerWash,
        p['danger'],
      ),
      StartupErrorCode.ledgerTooNew => (
        Icons.arrow_upward,
        p['fill-active'],
        p.secondary,
      ),
      StartupErrorCode.startupFailed => (
        Icons.info_outline,
        p['fill-active'],
        p.secondary,
      ),
    };
    final coreMissing = code == StartupErrorCode.appFilesMissing;
    final closePrimary = switch (code) {
      StartupErrorCode.alreadyRunning ||
      StartupErrorCode.diskFull ||
      StartupErrorCode.ledgerTooNew => true,
      _ => false,
    };
    final showDataDir =
        widget.dataDir != null &&
        (code == StartupErrorCode.dataDirDenied ||
            code == StartupErrorCode.diskFull);
    final mono = p
        .text(12, p.secondary)
        .copyWith(
          fontFamily: LensPalette.monoFonts.first,
          fontFamilyFallback: LensPalette.monoFonts.skip(1).toList(),
          fontVariations: const [],
        );
    Widget feedback(Color fill, List<Widget> children) => Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        copy.title,
                        style: p.text(17, p.ink, FontWeight.w600),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(copy.body, style: p.text(14, p.secondary)),
                    if (showDataDir) ...[
                      const SizedBox(height: 6),
                      SelectableText(widget.dataDir!, style: mono),
                    ],
                    if (copy.steps.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      for (final (i, step) in copy.steps.indexed)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${i + 1}. ',
                                style: p.text(14, p.secondary),
                              ),
                              Expanded(
                                child: Text(
                                  step,
                                  style: p.text(14, p.secondary),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                    if (widget.newsEnabled) ...[
                      const SizedBox(height: 8),
                      Text(s.startupNewsStillWorks, style: p.text(14, p.muted)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(left: constraints.maxWidth < 380 ? 0 : 50),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 22),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (coreMissing)
                      LensButton(
                        label: s.startupOpenAppFolder,
                        icon: Icons.folder_open,
                        variant: 'primary',
                        onPressed: widget.appDirectory == null
                            ? null
                            : () => _openFolder(widget.appDirectory!),
                      ),
                    if (!coreMissing && widget.exportDiagnostics != null)
                      LensButton(
                        label: _exporting ? s.exporting : s.exportDiagnostics,
                        icon: Icons.download,
                        variant: closePrimary ? 'secondary' : 'primary',
                        onPressed: _exporting ? null : _export,
                      ),
                    if (!coreMissing && widget.logDirectory != null)
                      LensButton(
                        label: s.startupOpenLogFolder,
                        icon: Icons.folder_open,
                        onPressed: () => _openFolder(widget.logDirectory!),
                      ),
                    if (widget.onClose != null)
                      LensButton(
                        label: s.close,
                        variant: closePrimary ? 'primary' : 'ghost',
                        onPressed: widget.onClose,
                      ),
                  ],
                ),
                if (_exportPath case final path?) ...[
                  const SizedBox(height: 14),
                  feedback(p.okWash, [
                    SelectableText(s.savedTo0(path), style: p.text(13)),
                    const SizedBox(height: 4),
                    LensButton(
                      label: s.openContainingFolder,
                      variant: 'ghost',
                      size: 'xs',
                      onPressed: () => _openFolder(File(path).parent.path),
                    ),
                  ]),
                ],
                if (_exportError case final error?) ...[
                  const SizedBox(height: 14),
                  feedback(p.dangerWash, [
                    Text(s.diagnosticsExportFailed(error), style: p.text(13)),
                    Text(s.startupExportFailureHelp, style: p.text(13)),
                  ]),
                ],
                if (_folderError case final format?) ...[
                  const SizedBox(height: 14),
                  feedback(p.dangerWash, [Text(format(s), style: p.text(13))]),
                ],
                const SizedBox(height: 14),
                Text(
                  coreMissing
                      ? s.startupPrivacyWithoutCore
                      : s.startupDiagnosticsPrivacy,
                  style: p.text(12, p.muted),
                ),
                const SizedBox(height: 16),
                Divider(height: 1, color: p['line-soft']),
                const SizedBox(height: 8),
                LensDisclosure(
                  expanded: _details,
                  onPressed: () => setState(() => _details = !_details),
                  child: Text(s.startupDetails, style: p.text(12, p.muted)),
                ),
                if (_details)
                  Table(
                    columnWidths: const {
                      0: IntrinsicColumnWidth(),
                      1: FlexColumnWidth(),
                    },
                    children: [
                      for (final (label, value) in [
                        (s.startupErrorCode, code.wire),
                        (s.version, widget.version),
                        (s.startupDataFolder, widget.dataDir ?? '—'),
                        (s.startupMessage, widget.failure.message),
                      ])
                        TableRow(
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(right: 14, top: 4),
                              child: Text(label, style: p.text(12, p.muted)),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: SelectableText(value, style: mono),
                            ),
                          ],
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
