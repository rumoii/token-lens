import 'app_strings.dart';

String localizedAnomaly(String raw, AppStrings strings) {
  final separator = raw.indexOf(':');
  if (separator < 0) return raw;
  final code = raw.substring(0, separator);
  // The prefix is stable. Text after the em dash is a diagnostic detail that
  // may have been written by an older version in a different language.
  final subject = raw.substring(separator + 1).split(' — ').first.trim();
  return switch (code) {
    'cross_file_conflict' => strings.anomalyCrossFileConflict(raw, subject),
    'rejected' => strings.anomalyRejected(raw, subject),
    'read_failed' => strings.anomalyReadFailed(raw, subject),
    'vanished' => strings.anomalyVanished(raw, subject),
    'cumulative_decrease' => strings.anomalyCumulativeDecrease(raw, subject),
    'superseded_reproduced' => strings.anomalySupersededReproduced(
      raw,
      subject,
    ),
    _ => raw,
  };
}

String? localizedWarnings(List<String> warnings, AppStrings strings) =>
    warnings.isEmpty
    ? null
    : warnings
          .map((warning) => localizedAnomaly(warning, strings))
          .join(strings.sentenceSeparator);
