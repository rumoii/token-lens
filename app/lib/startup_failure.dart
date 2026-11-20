enum StartupErrorCode {
  alreadyRunning('already_running'),
  appFilesMissing('app_files_missing'),
  dataDirDenied('data_dir_denied'),
  diskFull('disk_full'),
  ledgerCorrupt('ledger_corrupt'),
  ledgerTooNew('ledger_too_new'),
  startupFailed('startup_failed');

  const StartupErrorCode(this.wire);
  final String wire;
}

class StartupFailure {
  const StartupFailure(
    this.code,
    this.message, {
    this.ledgerVersion,
    this.supportedVersion,
  });

  final StartupErrorCode code;
  final String message;
  final int? ledgerVersion;
  final int? supportedVersion;
}

StartupFailure parseStartupFailure(Object error) {
  final text = error.toString();
  for (final code in StartupErrorCode.values) {
    final prefix = '${code.wire}:';
    if (!text.startsWith(prefix)) continue;
    final detail = text.substring(prefix.length);
    if (code == StartupErrorCode.ledgerTooNew) {
      final versions = RegExp(r'^(\d+):(\d+): ').firstMatch(detail);
      if (versions != null) {
        return StartupFailure(
          code,
          detail.substring(versions.end),
          ledgerVersion: int.tryParse(versions[1]!),
          supportedVersion: int.tryParse(versions[2]!),
        );
      }
    }
    return StartupFailure(code, detail.trimLeft());
  }
  return StartupFailure(StartupErrorCode.startupFailed, text);
}
