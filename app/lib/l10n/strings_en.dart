part of 'app_strings.dart';

final class EnglishStrings extends AppStrings {
  @override
  String get miniWindow => 'Compact window';

  @override
  String get miniHintTitle =>
      'Want to watch token usage while you work with AI?';

  @override
  String get miniHintDescription =>
      'The compact window stays on top in a corner, showing today\'s usage and the models in use.';

  @override
  String get miniHintOpen => 'Open compact window';

  @override
  String get miniHintDismiss => 'Don\'t show again';

  @override
  String get onboardingShortcut => 'Create a desktop shortcut';

  @override
  String get onboardingShortcutHint =>
      'Puts a Token Lens icon on your desktop so you can open it with a double-click.';

  @override
  String get onboardingShortcutCreated => 'Desktop shortcut created';

  @override
  String get onboardingShortcutFailed =>
      'Couldn\'t create the desktop shortcut. You can try again later in Pricing & settings.';

  @override
  String get desktopShortcut => 'Desktop shortcut';

  @override
  String get desktopShortcutHint =>
      'Puts a Token Lens icon on your desktop. If you moved the app folder, create it again here.';

  @override
  String get desktopShortcutCreate => 'Create shortcut';

  @override
  String get desktopShortcutRecreate => 'Create again';

  @override
  String get desktopShortcutCreated => 'Created';

  @override
  String get desktopShortcutFailed => 'Couldn\'t create the desktop shortcut.';

  @override
  String get miniPin => 'Keep on top';

  @override
  String get miniUnpin => 'Stop keeping on top';

  @override
  String get miniSettings => 'Compact window settings';

  @override
  String get miniExpand => 'Open full window';

  @override
  String get miniPillEnter => 'Shrink to mini mode';

  @override
  String miniPillLabel(String tokens, String cost) =>
      'Today $tokens tokens, about $cost. Click to open the compact window';

  @override
  String get miniPillTooltip =>
      'Click to open the compact window. Drag to the left or right edge of the screen to tuck it away.';

  @override
  String miniEstimate(String amount) => 'Est. $amount';

  @override
  String miniInterval(int seconds) =>
      seconds < 60 ? '${seconds}s' : '${seconds ~/ 60} min';

  @override
  String miniUpdated(int age, int interval) => age < 2
      ? 'Updated just now · every ${miniInterval(interval)}'
      : 'Updated ${age < 60 ? '${age}s' : '${age ~/ 60}m'} ago · every ${miniInterval(interval)}';

  @override
  String get miniSyncFailed => 'Sync failed. Showing earlier data.';

  @override
  String get miniProjects => 'Projects';

  @override
  String miniTopProjects(int count) => 'Top $count projects';

  @override
  String get miniAllProjects => 'All projects';

  @override
  String miniLatest(int count) => 'Latest $count';

  @override
  String miniMoreProjects(int count) =>
      '$count more ${count == 1 ? 'project' : 'projects'}';

  @override
  String get miniActiveModels => 'Active models · last 5 min';

  @override
  String miniMoreModels(int count) =>
      '$count more ${count == 1 ? 'model' : 'models'}';

  @override
  String miniApproxSpeed(String value) => '≈ $value tokens/s';

  @override
  String miniUntimedModel(String tool) =>
      "$tool doesn't log generation time, so this shows usage in the last 5 min.";

  @override
  String miniOutput(String value) => 'Output $value';

  @override
  String miniFirstToken(String seconds) => 'First token ${seconds}s';

  @override
  String miniHour(int hour) => "${hour.toString().padLeft(2, '0')}:00";

  @override
  String get miniNoUsage => 'No usage yet today';

  @override
  String get miniNoRequests => 'No requests yet today';

  @override
  String get miniNoModels => 'No models used in the last 5 min';

  @override
  String get miniChartRange => 'Chart range';

  @override
  String miniChartChoice(int minutes) =>
      minutes == 60 ? '1 hour' : '$minutes min';

  @override
  String get miniChartNow => 'Now';

  @override
  String miniChartTip(String time, String usage, bool current) =>
      "$time${current ? ' so far' : ''} · $usage tokens";

  @override
  String miniChartLabel(int minutes) =>
      'Usage in the last $minutes min, one point per minute';

  @override
  String get miniRefreshEvery => 'Refresh every';

  @override
  String get miniProjectsShown => 'Projects shown';

  @override
  String miniProjectsChoice(int count) => switch (count) {
    -1 => 'Fit window',
    0 => 'All',
    _ => 'Top $count',
  };

  @override
  String get miniSwitchFailed => 'Could not switch window mode.';

  @override
  StartupFailureCopy startupFailureCopy(
    StartupFailure failure,
  ) => switch (failure.code) {
    StartupErrorCode.alreadyRunning => (
      title: 'Token Lens is already running',
      body: 'Another Token Lens window is using this data folder. Return to that window.',
      steps: const [
        'Look for the Token Lens window on the taskbar.',
        'If you cannot find it, end token-lens.exe in Task Manager and open the app again.',
      ],
    ),
    StartupErrorCode.appFilesMissing => (
      title: 'App files are incomplete',
      body: 'The Token Lens core could not load. Usually only token-lens.exe was copied, or the archive was not fully extracted.',
      steps: const [
        'Extract the whole archive again.',
        'Keep token-lens.exe next to its DLLs and the data folder.',
      ],
    ),
    StartupErrorCode.dataDirDenied => (
      title: 'No permission to use the data folder',
      body: 'Token Lens reads and writes its ledger and settings in the folder below, but access was denied.',
      steps: const [
        'Check that the folder is not read-only or blocked by security software.',
        'If it is inside a synced folder such as OneDrive, wait for syncing to finish.',
      ],
    ),
    StartupErrorCode.diskFull => (
      title: 'Not enough disk space',
      body: 'The disk that holds the data folder is full, so Token Lens cannot write its ledger. Free up some space and open the app again.',
      steps: const [],
    ),
    StartupErrorCode.ledgerCorrupt => (
      title: 'The usage ledger is damaged',
      body: 'ledger.db cannot be read. Do not delete it: export diagnostics for the maintainer before deciding how to recover.',
      steps: const [],
    ),
    StartupErrorCode.ledgerTooNew => (
      title: 'The ledger is from a newer Token Lens',
      body:
          'This ledger uses structure version ${failure.ledgerVersion ?? '—'}; this Token Lens supports up to ${failure.supportedVersion ?? '—'}. To keep your data safe it will not write to it. Use the newer Token Lens instead.',
      steps: const [],
    ),
    StartupErrorCode.startupFailed => (
      title: 'Token Lens could not start',
      body: 'Startup hit an unexpected error. Exporting diagnostics for the maintainer helps find the cause.',
      steps: const [],
    ),
  };

  @override
  String get startupOpenLogFolder => 'Open log folder';

  @override
  String get startupOpenAppFolder => 'Open app folder';

  @override
  String get startupDiagnosticsPrivacy =>
      'Diagnostics include app and system versions, the cause and the last 7 days of runtime logs. No ledger, no conversation content; your home folder shows as ~.';

  @override
  String get startupPrivacyWithoutCore =>
      'The app core did not load, so diagnostics cannot be exported from this page.';

  @override
  String get startupDetails => 'Details';

  @override
  String get startupErrorCode => 'Error code';

  @override
  String get startupDataFolder => 'Data folder';

  @override
  String get startupMessage => 'Message';

  @override
  String get startupStatisticsUnavailable => 'Statistics unavailable';

  @override
  String get startupOverview => 'Overview';

  @override
  String get startupDetail => 'Detail';

  @override
  String get startupSessions => 'Sessions';

  @override
  String get startupNewsStillWorks => 'AI news still works.';

  @override
  String get startupExportFailureHelp =>
      'Open the log folder and send the latest log to the maintainer instead.';

  @override
  String get startupExportDestinationUnavailable =>
      'The Downloads and data folders are unavailable.';

  @override
  String get spansPeriod => 'Spans period';

  @override
  String get copySessionId => 'Copy session ID';

  @override
  String get sessionIdCopied => 'Session ID copied';

  @override
  String heatTokenRange(String from, String to) => '$from–$to tokens';

  @override
  String heatTokensAndAbove(String from) => '$from tokens and above';

  @override
  String discoveredLogTools(int count) =>
      'Found logs for $count tools on this computer';

  @override
  String discoveredLogFiles(int count) => '$count files';

  @override
  String moreDiscoveredTools(int count) => '$count more';

  @override
  String get noSupportedToolsDiscovered =>
      'No supported AI coding tools found on this computer yet';

  @override
  String get completionByTool => byTool;

  @override
  String completionToolCount(int count) => '$count tools';

  @override
  String otherCompletionTools(int count) => '$count other tools';

  @override
  String completionTokenEstimate(String cost) => 'tokens · est. $cost';

  @override
  String get morePeriods => 'More';

  @override
  String get lastSevenDays => 'Last 7 days';

  @override
  String get lastThirtyDays => 'Last 30 days';

  @override
  String get lastSevenDaysInSentence => 'the last 7 days';

  @override
  String get lastThirtyDaysInSentence => 'the last 30 days';

  @override
  String get dayBeforeYesterday => 'the day before';

  @override
  String get weekBeforeLast => 'the week before';

  @override
  String get monthBeforeLast => 'the month before';

  @override
  String get previousSevenDays => 'the previous 7 days';

  @override
  String get previousThirtyDays => 'the previous 30 days';

  @override
  String comparisonDates(String current, int n, String previous, int m) =>
      comparisonDateRanges('$current ($n days)', '$previous ($m days)');

  @override
  String comparisonDateRanges(String current, String previous) =>
      '$current vs. $previous';

  @override
  String get sessionSearch => 'Search projects, session IDs, tools or models';

  @override
  String noMatchingSessions(String q) => 'No sessions match “$q”';

  @override
  String get clearSessionSearch => 'Clear';

  @override
  String get sessionSortCost => 'Cost';

  @override
  String get sessionSortStarted => 'Started';

  @override
  String get sessionSortRecent => 'Last active';

  @override
  String get sessionSortRequests => 'Requests in period';

  @override
  String get sortDescending => 'Descending';

  @override
  String get sortAscending => 'Ascending';

  @override
  String sortedSessions(String period, String sort) =>
      'Sessions with usage ($period), sorted by $sort. Totals cover the full session.';

  @override
  String sessionSortUsageInSentence(String periodLabel) =>
      'usage in that period';

  @override
  String get sessionSortCostInSentence => 'cost';

  @override
  String get sessionSortStartedInSentence => 'start time';

  @override
  String get sessionSortRecentInSentence => 'last activity';

  @override
  String get sessionSortRequestsInSentence => 'requests in that period';

  @override
  String get filterSearch => 'Search';

  @override
  String get noMatchingOptions => 'No matching options';

  @override
  String get seeWhatChanged => 'See what changed →';

  @override
  String get whatChangedFromPrevious => 'What changed from the previous period';

  @override
  String get comparisonCurrent => 'This period';

  @override
  String get comparisonPrevious => 'Previous period';

  @override
  String get comparisonChange => 'Change';

  @override
  String get sortedBySizeOfChange => 'Sorted by size of change';

  @override
  String get comparisonNew => 'New';

  @override
  String get comparisonUnused => 'Not used';

  @override
  String showMoreComparisonRows(int n) => 'Show $n more';

  @override
  String get noUsageInEitherPeriod => 'No usage in either period';

  @override
  String get partlyUnpriced => 'Partly unpriced';

  @override
  String get comparisonUnpricedNote =>
      'Some records are unpriced; cost covers priced records only.';

  @override
  String biggestIncrease(String project, String n) =>
      'The biggest increase was $project (+$n tokens).';

  @override
  String biggestDrop(String project, String n) =>
      'The biggest drop was $project (−$n tokens).';

  @override
  String compareWith(String previous) =>
      'Compare with ${_lowerInitial(previous)}';

  @override
  String get comparisonPreviousColumn => 'Previous';

  @override
  String get noComparisonPeriod =>
      'All time and custom ranges have no previous period';

  @override
  String get trendTokens => 'Tokens';

  @override
  String get trendCost => 'Cost';

  @override
  String get trendUnpricedNote => 'Unpriced usage is not included in cost.';

  @override
  String inventoryIntro(int total, int found) =>
      'Supports $total AI coding tools; $found found on this computer. Token Lens reads local logs only, uploads nothing and leaves tools unchanged.';

  @override
  String get inventoryFound => 'Found';

  @override
  String get inventoryIssues => 'Issues';

  @override
  String get inventoryHidden => 'Hidden';

  @override
  String get inventoryMissing => 'Not installed';

  @override
  String get inventorySearch => 'Search tools or paths';

  @override
  String get inventoryVisibility =>
      'Hiding only affects display: hidden tools leave the overview, breakdown, sessions and sidebar, but their logs are still read and recorded. You can show them again at any time.';

  @override
  String get inventoryFolder => 'Log folder';

  @override
  String get inventoryFiles => 'Files';

  @override
  String get inventoryLastUsed => 'Last used';

  @override
  String get inventoryShow => 'Show';

  @override
  String get inventoryDenied => 'No permission';

  @override
  String get inventoryReadError => 'Read error';

  @override
  String inventoryMonth(String value) => '$value this month';

  @override
  String inventoryFilesFound(int n) => '$n ${n == 1 ? "file" : "files"} found';

  @override
  String get inventoryPathMissing => 'Not found';

  @override
  String get inventoryLocations => 'Token Lens looks for logs here';

  @override
  String get inventoryOpen => 'Open';

  @override
  String get inventoryCopy => 'Copy path';

  @override
  String get inventoryCopied => 'Copied';

  @override
  String get inventoryShowInStats => 'Show in statistics';

  @override
  String get inventoryViewUsage => 'View usage';

  @override
  String progressSyncing(String tool) => 'Syncing · $tool';

  @override
  String get progressSynced => 'Synced';

  @override
  String progressDiscovering(String title) => '$title: looking for log folders';

  @override
  String progressReading(
    String title,
    String tool,
    int index,
    int total,
    int files,
  ) =>
      '$title: reading $tool ($index of $total tools) · $files ${files == 1 ? "file" : "files"} read. Tools appear as they finish; you can keep browsing.';

  @override
  String get progressFirst => 'First sync';

  @override
  String get progressReread => 'Rereading all logs';

  @override
  String get progressFirstHint =>
      'The first sync is still running. Below is what has been read so far.';

  @override
  String progressFailed(String reason) => 'Sync failed: $reason';

  @override
  String get progressEarlierDataPreserved =>
      'Previously collected data is still available.';

  @override
  String progressIssues(int n) =>
      'Sync finished with $n ${n == 1 ? "issue" : "issues"}';

  @override
  String get progressDismiss => 'Dismiss';

  @override
  String hiddenToolsNotice(int n) => '$n ${n == 1 ? "tool" : "tools"} hidden';

  @override
  String get hiddenToolsManage => 'Manage';

  const EnglishStrings();

  @override
  String get languageCode => 'en';

  bool _isOne(Object? count) => count == 1 || count == '1';

  @override
  String get aDashMeansTheLogOmitsThe =>
      'A dash means the log omits the value. Hover to see why. Brown marks the slowest 10%. ≈ marks average speed including wait time. ';

  @override
  String get aRealSamples => 'A (real samples)';

  @override
  String get aRefreshIsAlreadyRunningWaitFor =>
      'A refresh is already running. Wait for it to finish.';

  @override
  String get aSessionIsATaskInAn => 'A session is a task in an AI coding tool';

  @override
  String get aSessionIsATaskInAn2 =>
      'A session is a task in an AI coding tool, newest first. Select one to see which models it used and when.';

  @override
  String get aSyncIsAlreadyRunningWaitingFor =>
      'A sync is already running. Waiting for it to finish';

  @override
  String about0(Object? shortName) => 'About $shortName';

  @override
  String about0TokenS(Object? value) => 'About $value tokens/s';

  @override
  String get aboutThisInstallationOfTokenLens =>
      'About this installation of Token Lens';

  @override
  String activeDayCount(Object? active) =>
      '$active active ${_isOne(active) ? 'day' : 'days'}';

  @override
  String get activeDays => 'Active days';

  @override
  String get activeEveryDaySinceTrackingBegan =>
      'Active every day since tracking began';

  @override
  String get affectsData => 'Affects data';

  @override
  String get afterSyncingYouLlSeeHowMany =>
      'After syncing, you\'ll see how many tokens each AI coding tool used.';

  @override
  String get appearanceAndInterface => 'Appearance';

  @override
  String get numbersAndTime => 'Numbers and time';

  @override
  String get networkAndUpdates => 'Network and updates';

  @override
  String get interfaceDensity => 'Density';

  @override
  String get densityHint =>
      'Compact mode tightens card and table spacing so more rows fit';

  @override
  String get comfortableDensity => 'Comfortable';

  @override
  String get compactDensity => 'Compact';

  @override
  String get interfaceScale => 'Interface scale';

  @override
  String get interfaceScaleHint =>
      'Scales the interface on top of the system display scaling';

  @override
  String get resetInterfaceScale => 'Reset to 100%';

  @override
  String get defaultPeriod => 'Default period';

  @override
  String get defaultPeriodHint =>
      'The period the overview and breakdown open on';

  @override
  String get lastUsedPeriod => 'Last used';

  @override
  String get weekStartsOn => 'Week starts on';

  @override
  String get weekStartsOnHint =>
      'Affects This week, the heatmap and week comparisons';

  @override
  String get monday => 'Monday';

  @override
  String get sunday => 'Sunday';

  @override
  String get newsPreferenceHint =>
      'Shown in the sidebar and refreshed every 30 minutes while the app is open. Turn this off to stop fetching news.';

  @override
  String get localStatisticsOnly => 'Local statistics only, no AI news';

  @override
  String get localStatisticsOnlyHint =>
      'Hides AI news and stops fetching news. You can turn it on later in Pricing & settings.';

  @override
  String get aiNews => 'AI news';

  @override
  String get aiNewsIsClosedReopenTheWindow =>
      'AI news is closed. Reopen the window.';

  @override
  String get aiSummary => 'AI summary  ';

  @override
  String get aiSummary2 => 'AI summary';

  @override
  String get aihotPicksComeFromThePublicRss =>
      'AIHOT picks come from the public RSS feed at aihot.news. Its model generates the titles and summaries. Article links point to the original sources.';

  @override
  String get all => 'All';

  @override
  String get allCaughtUp => 'All caught up';

  @override
  String get allSessionsShown => 'All sessions shown';

  @override
  String get allTime2 => 'All time';

  @override
  String get allUnread => ', all unread';

  @override
  String get alreadyFilteredByThisFieldTryAnother =>
      'Already filtered by this field. Try another breakdown.';

  @override
  String alsoOn0(Object? value) => 'Also on $value';

  @override
  String get anOlderCollectorLockWasFoundClose =>
      'An older collector lock was found. Close the old app before clearing the lock file.';

  @override
  String anomalyCrossFileConflict(String raw, String record) =>
      'Conflicting usage in two copies of the same record: $record';

  @override
  String anomalyCumulativeDecrease(String raw, String subject) =>
      'A session total went down. Its previous total still counts: $subject';

  @override
  String anomalyReadFailed(String raw, String subject) =>
      'Could not read a log: $subject';

  @override
  String anomalyRejected(String raw, String subject) =>
      'Skipped usage that could not be added to the ledger: $subject';

  @override
  String anomalySupersededReproduced(String raw, String record) =>
      'Skipped a record that was already replaced: $record';

  @override
  String anomalyVanished(String raw, String subject) =>
      'Records disappeared from a log. Their previous usage still counts: $subject';

  @override
  String get appearance => 'Theme';

  @override
  String get apply => 'Apply';

  @override
  String get asksApiGithubComForTheLatest =>
      'Only asks api.github.com for the latest stable release, without sending account, credential or usage data. Turn this off to check only when you select Check for updates.';

  @override
  String get atListPrices => 'Estimated at list prices';

  @override
  String atListPrices0RecordWithoutA(Object? value) =>
      'Estimated at list prices · $value unpriced ${_isOne(value) ? 'record' : 'records'}';

  @override
  String get autoRefresh => 'Auto-refresh';

  @override
  String average0PerSession(Object? value) => 'Avg. $value per session';

  @override
  String get averageSpeed => 'Average speed';

  @override
  String get averageSpeedIncludesTheWait => 'Average speed (including wait)';

  @override
  String avg0(Object? tokens) => 'Avg. $tokens';

  @override
  String get avgPerRequest => 'Avg. per request';

  @override
  String get averagePerRequestPrefix => 'Avg. per request ';

  @override
  String get bSyntheticSamples => 'B (synthetic samples)';

  @override
  String get baseTier => 'Base tier';

  @override
  String get breakdown => 'Breakdown';

  @override
  String get breakdown2 => 'Breakdown';

  @override
  String breakdownDescription(String period) =>
      'Usage for $period, broken down by tool, model, project and time.';

  @override
  String get builtInRate => 'Built-in rate';

  @override
  String get busiestDay => 'Busiest day';

  @override
  String get busiestHour => 'Busiest hour';

  @override
  String get byDay => 'By day';

  @override
  String get byHour => 'By hour';

  @override
  String get byModel => 'By model';

  @override
  String get byPopularity => 'By popularity';

  @override
  String get byProject => 'By project';

  @override
  String get byRequest => 'By request';

  @override
  String get byTime => 'By time';

  @override
  String get byTool => 'By tool';

  @override
  String get cache => 'Cache';

  @override
  String get cacheHit => 'Cache hit';

  @override
  String cacheHit0(Object? periodLabel) => 'Cache hit · $periodLabel';

  @override
  String get cacheRead => 'Cache read';

  @override
  String get cacheReadsNewInputCacheReadsHigher =>
      'Cache read ÷ (input + cache read). Higher means lower cost.';

  @override
  String get cacheSavings => 'Cache savings';

  @override
  String get cacheSavings2 => 'Cache savings  ⓘ';

  @override
  String get cacheWrite => 'Cache write';

  @override
  String get cacheWrite1h => 'Cache write (1h)';

  @override
  String get cacheWrite5m => 'Cache write (5m)';

  @override
  String get cacheWriteShort => 'Cache write (short)';

  @override
  String get cachedArticlesAreStillAvailableYouCan =>
      'Cached articles are still available. You can refresh again at any time.';

  @override
  String calendarDay(int month, int day) => '${shortMonth(month)} $day';

  @override
  String calendarDayWeekdayWithYear(
    int year,
    int month,
    int day,
    int weekday,
  ) => '${calendarDayWithYear(year, month, day)}, ${shortWeekday(weekday)}';

  @override
  String calendarDayWithWeekday(int month, int day, int weekday) =>
      '${calendarDay(month, day)}, ${shortWeekday(weekday)}';

  @override
  String calendarDayWithYear(int year, int month, int day) =>
      '${calendarDay(month, day)}, $year';

  @override
  String calendarMonth(int year, int month) => '${shortMonth(month)} $year';

  @override
  String get cancel => 'Cancel';

  @override
  String get cancelRefresh => 'Cancel refresh';

  @override
  String get canceled => 'Canceled';

  @override
  String get canceling => 'Canceling';

  @override
  String get cancelingRefresh => 'Canceling refresh…';

  @override
  String get cannotReadLogDirectory => 'No permission to read log directory';

  @override
  String chartSpanningSessions(Object? tokens, Object? unit) =>
      'Totals above include $tokens tokens from session snapshots spanning more than one $unit. The chart omits them.';

  @override
  String chartUnallocatedUsage(
    Object? tokens,
    Object? spanUnit,
    Object? bucketUnit,
  ) =>
      'Totals above include $tokens tokens from session snapshots spanning more than one $spanUnit. Their usage cannot be split by $bucketUnit, so the chart omits them.';

  @override
  String get checkAutomaticallyOnceADay => 'Check automatically once a day';

  @override
  String get checkForUpdates => 'Check for updates';

  @override
  String checkedAt(Object? time) => 'Checked $time';

  @override
  String get checkedAgainstPublicReferencesAndSamplesReport =>
      'Checked against public references and samples; likely accurate. Report any discrepancies.';

  @override
  String get checkedAgainstRealUsageLogs =>
      'Verified record by record against real usage logs. Counts are reliable.';

  @override
  String get checkedAgainstTheProviderSPricingPage =>
      'Verified against the provider\'s pricing page.';

  @override
  String get checkedWithSampleLogs => 'Sample logs only';

  @override
  String get checking => 'Checking…';

  @override
  String get checks => 'Checks';

  @override
  String get checksPassed => 'Checks passed';

  @override
  String get chinaStandardTimeUtc8 => 'China Standard Time (UTC+8)';

  @override
  String get chinese => 'Chinese';

  @override
  String get chineseLanguage => 'Chinese';

  @override
  String get clear => 'Clear';

  @override
  String get clearFilters => 'Clear filters';

  @override
  String get clearSearch => 'Clear search';

  @override
  String get close => 'Close';

  @override
  String get closeNavigationMenu => 'Close navigation menu';

  @override
  String closePanel(String label) => 'Close $label';

  @override
  String get cny => 'CNY ¥';

  @override
  String get community => 'Community';

  @override
  String conditionalPriceTableLabel(Object? value) =>
      'Conditional prices for $value';

  @override
  String get cost => 'Cost';

  @override
  String get costsAreEstimatesAtEachModelS3 =>
      'Costs are estimated at each model\'s list price for comparison, not your bill. Subscription users usually pay less.';

  @override
  String couldNotAccessLogDirectoriesFor0(Object? count) =>
      'No permission to read log directories for $count ${_isOne(count) ? 'tool' : 'tools'}, listed below. Other supported tools were not found on this computer.';

  @override
  String get couldNotCancelWaitForTheCurrent =>
      'Could not cancel. Wait for the current refresh to finish.';

  @override
  String syncStatusReadFailed(Object? failure) =>
      'Could not confirm sync status: $failure';

  @override
  String get couldNotLoadRequestFailed => 'Could not load (request_failed)';

  @override
  String exportFolderOpenFailed(Object? error) =>
      'Could not open folder: $error';

  @override
  String get couldNotOpenTheArticleCheckYour =>
      'Could not open the article. Check your default browser settings.';

  @override
  String get couldNotOpenTheContainingFolder =>
      'Could not open the containing folder';

  @override
  String get couldNotParse => 'Could not parse';

  @override
  String get couldNotParseThisSourceCachedArticles =>
      'Could not parse this source. Cached articles are unchanged.';

  @override
  String get couldNotReachTheSourceCheckYour =>
      'Could not reach the source. Check your connection and try again.';

  @override
  String get couldNotReadLocalStatusAfterRefresh =>
      'Could not read local status after refresh. Try refreshing again.';

  @override
  String get couldNotReadOrSaveLocalStatus =>
      'Could not read or save local status. Articles are still available. Your changes may not be saved.';

  @override
  String get couldNotReadTheLocalCacheTry =>
      'Could not read the local cache. Try refreshing.';

  @override
  String get couldNotSaveReadStatus => 'Could not save read status.';

  @override
  String get couldNotSaveSourceSettings => 'Could not save source settings.';

  @override
  String get couldNotSaveStarredStatus => 'Could not save starred status.';

  @override
  String exchangeRateUpdateFailed(Object? failure) =>
      'Could not update exchange rate: $failure';

  @override
  String get counting => 'Counting…';

  @override
  String get currency => 'Currency';

  @override
  String get currencyUsedToDisplayCosts => 'Currency used to display costs';

  @override
  String get custom => 'Custom';

  @override
  String get dailyAverage => 'Daily average';

  @override
  String get dailyUsageForThisSessionTodayIs =>
      'Daily usage for this session. Today is highlighted';

  @override
  String get dark => 'Dark';

  @override
  String get dataDirectory => 'Data directory';

  @override
  String get date => 'Date';

  @override
  String get day => 'day';

  @override
  String dayCount(Object? streak) =>
      '$streak ${_isOne(streak) ? 'day' : 'days'}';

  @override
  String daysAgo(Object? days) => _isOne(days) ? 'yesterday' : '$days days ago';

  @override
  String get debugRunsRequireTokenLensPreviewData =>
      'Debug runs require TOKEN_LENS_PREVIEW_DATA_DIR and TOKEN_LENS_PREVIEW_HOME to point to separate absolute directories.';

  @override
  String get deprecation => 'Deprecation';

  @override
  String get diagnosticsAbout => 'Diagnostics & about';

  @override
  String get didNotUpdate => 'Did not update';

  @override
  String get disable => 'Disable';

  @override
  String get disabled => 'Disabled';

  @override
  String get dismissThisVersion => 'Dismiss this version';

  @override
  String get display => 'Display';

  @override
  String get displayOnlyLedgerAmountsStayTheSame =>
      'Display only. Ledger amounts stay the same. The exchange rate is fetched only when you select Update rate, and the current rate is kept if the request fails.';

  @override
  String get displayPreferencesAndHowCostsAreCalculated =>
      'Display preferences and how costs are calculated.';

  @override
  String get duration => 'Duration';

  @override
  String get eachRequestIncludesItsTimeModelAnd =>
      'Each request includes its time, model and usage.';

  @override
  String get eachSquareIsADayDarkerSquares =>
      'Each square is a day. Darker squares mean more usage';

  @override
  String emptyPeriodHint(Object? period) =>
      'No usage for $period. Try another date range or sync after the tools write new logs.';

  @override
  String get enable => 'Enable';

  @override
  String get enableOrDisableSourcesAndCheckRefresh =>
      'Enable or disable sources and check refresh status';

  @override
  String get enabledSourcesHaveNoArticlesToShow =>
      'Enabled sources have no articles to show. The app refreshes every 30 minutes.';

  @override
  String get englishLanguage => 'English';

  @override
  String get enterAValidDateRange => 'Enter a valid date range';

  @override
  String get estCost => 'Est. cost';

  @override
  String estCost0(Object? periodLabel) => 'Est. cost · $periodLabel';

  @override
  String estCost02(Object? value) => 'Est. cost ($value) ';

  @override
  String get estimatedCostPrefix => 'Est. cost ';

  @override
  String get estimatedAtListPrices => 'Estimated at list prices, not a bill';

  @override
  String get estimatedFromLogTimestamps => 'Estimated from log timestamps';

  @override
  String get estimatedFromReasoningStartEvents =>
      'Estimated from reasoning start events';

  @override
  String get estimatedFromWeeklyShare => 'Estimated from weekly share';

  @override
  String get estimatedPrice => 'Estimated price';

  @override
  String get evidence => 'Evidence';

  @override
  String example0(Object? value) => 'Example: $value';

  @override
  String exchangeRate(Object? rate, Object? updated) =>
      '1 USD ≈ $rate CNY · $updated';

  @override
  String get exportDiagnostics => 'Export diagnostics';

  @override
  String diagnosticsExportFailed(Object? error) => 'Export failed: $error';
  @override
  String get export => 'Export';
  @override
  String get exportCsv => 'Export CSV';
  @override
  String get exportJson => 'Export JSON';
  @override
  String get includeFullProjectPaths => 'Include full project paths';
  @override
  String exportCompleted(String name) => 'Exported $name';

  @override
  String get exporting => 'Exporting…';

  @override
  String newsFetchProgress(Object? completed, Object? total) =>
      'Fetching news · $completed/$total sources done';

  @override
  String get filterBySourceAndType => 'Filter by source and type';

  @override
  String get firstToken => 'First token';

  @override
  String get firstToken2 => 'First token ';

  @override
  String get firstTokenWaitForTheReply =>
      'Time to first token (wait before reply)';

  @override
  String get followSystem => 'Follow system';

  @override
  String get found => 'Found';

  @override
  String get foundTheLogDirectoryButCouldNot =>
      'Found the log directory but could not read it. Check folder permissions, then select Scan again.';

  @override
  String get fri2 => 'Fri';

  @override
  String get from => 'From';

  @override
  String get fullSessionTotal => 'Full session total';

  @override
  String get generalNoLabel => 'General (no label)';

  @override
  String get getANoticeWhenANewVersion =>
      'Get a notice when a new version is available and download it from GitHub releases. The app never downloads or installs updates automatically.';

  @override
  String get githubStars => 'GitHub stars';

  @override
  String noonGreeting(int hour) =>
      hour < 12 ? 'Good morning' : 'Good afternoon';

  @override
  String get goodAfternoon2 => 'Good afternoon';

  @override
  String get goodEvening => 'Good evening';

  @override
  String get goodMorning => 'Good morning';

  @override
  String get groupBy => 'Group by';

  @override
  String get hackerNewsPoints => 'Hacker News points';

  @override
  String get handled => 'Handled';

  @override
  String get highestFirst => 'Highest first';

  @override
  String holidayCountAndEnd(Object? days, Object? lastDate) =>
      ' ($days ${_isOne(days) ? 'day' : 'days'}, through $lastDate)';

  @override
  String holidayPricingNote(Object? holidays, Object? range) =>
      '$holidays$range. Day of week and time still apply in years without a holiday list.';

  @override
  String holidaysListedThrough0(Object? value) =>
      'Holidays listed through $value';

  @override
  String get hour => 'hour';

  @override
  String hourTick(Object? value) => '$value:00';

  @override
  String hoursAndMinutesDuration(Object? value1, Object? value2) =>
      '$value1 hr $value2 min';

  @override
  String daysAndHoursDuration(int days, int hours) =>
      hours == 0 ? '$days d' : '$days d $hours hr';

  @override
  String get howLargeNumbersAreShortened => 'How large numbers are shortened';

  @override
  String get howPricesWork => 'How prices work';

  @override
  String get huggingFaceLikes => 'Hugging Face likes';

  @override
  String get huggingFacePaperUpvotes => 'Hugging Face paper upvotes';

  @override
  String get ifUsageLooksWrongSyncFailsOr =>
      'If usage looks wrong, sync fails or the app freezes, export diagnostics to share with the maintainer.';

  @override
  String includes0LocalRecordZeroCost(Object? count) =>
      'Includes $count local ${_isOne(count) ? 'record' : 'records'} · Zero cost';

  @override
  String get includesAllUsage => 'Not affected by filters';

  @override
  String get includesAppAndSystemVersionsResultsAnd =>
      'Includes app and system versions, results and warnings from the last 10 syncs, log counts and paths for each tool, and app logs from the last 7 days.\nExcludes the ledger and conversation content. Your home directory appears as ~.';

  @override
  String get incompletePromptLengthBaseTier =>
      'Incomplete prompt length · Base tier';

  @override
  String inputOutputPrices(Object? input, Object? output) =>
      'Input $input · Output $output';

  @override
  String get installAndUseASupportedToolThen =>
      'Install and use a supported tool, then select Sync now to see it above.';

  @override
  String get interfaceLanguage => 'Language';

  @override
  String invalidUpdateCheckResponse(Object? checked, Object? retry) =>
      'Could not read the GitHub response · $checked. $retry';

  @override
  String get justNow => 'just now';

  @override
  String get knownLimitations => 'Known limitations';

  @override
  String get last20Weeks => 'Last 20 weeks';

  @override
  String get lastMonth => 'Last month';

  @override
  String lastSuccessfulRefresh0(Object? value) =>
      'Last successful refresh: $value';

  @override
  String get lastSyncDetails => 'Last sync details';

  @override
  String lastUsed0(Object? value) => 'Last used $value · ';

  @override
  String get lastWeek => 'Last week';

  @override
  String get latest => 'Latest';

  @override
  String get ledgerPath => 'Ledger path';

  @override
  String get less => 'Less';

  @override
  String get light => 'Light';

  @override
  String get lightDarkOrSystemTheme => 'Light, dark or system theme';

  @override
  String get likes => 'likes';

  @override
  String listPriceWithUnpricedRecords(Object? count) =>
      'Estimated at list prices · $count unpriced ${_isOne(count) ? 'record' : 'records'}';

  @override
  String get listSeparator => ', ';

  @override
  String get loadMore => 'Load more';

  @override
  String get loading => 'Loading';

  @override
  String get loadingSession => 'Loading session…';

  @override
  String get loadingUsageForThisPeriod => 'Loading usage for this period…';

  @override
  String get local => 'Local';

  @override
  String get localProviderZeroCost => 'Local provider · Zero cost';

  @override
  String logFileCount(Object? value) =>
      '$value log ${_isOne(value) ? 'file' : 'files'}';

  @override
  String get logRetention => 'Log retention';

  @override
  String logsGone(Object? value) =>
      'Logs for $value more ${_isOne(value) ? 'record are' : 'records are'} gone. Their usage still counts, but cannot be rechecked.';

  @override
  String longContextPrompt0Tokens(Object? count) =>
      'Long context (prompt > $count tokens)';

  @override
  String longContextSummary(Object? threshold, Object? count) =>
      'Long prompts over $threshold tokens use the higher rate: $count ${_isOne(count) ? 'record' : 'records'}';

  @override
  String get longContextTiers => 'Long-context tiers';

  @override
  String get longestStreak => 'Longest streak';

  @override
  String longestStreakDays(Object? streak) =>
      'Longest streak: $streak ${_isOne(streak) ? 'day' : 'days'}';

  @override
  String get lowestFirst => 'Lowest first';

  @override
  String get manageSources => 'Manage sources';

  @override
  String get markAllAsRead => 'Mark all as read';

  @override
  String get markAsRead => 'Mark as read';

  @override
  String get markAsUnread => 'Mark as unread';

  @override
  String get markThisDayAsRead => 'Mark this day as read';

  @override
  String minutesDuration(Object? minutes) => '$minutes min';

  @override
  String missingFromLogs0(Object? missing) => 'Missing from logs: $missing';

  @override
  String get model => 'Model';

  @override
  String modelCount(Object? models) =>
      '$models ${_isOne(models) ? 'model' : 'models'}';

  @override
  String get modelNotLogged => 'Model not logged';

  @override
  String get modelsAppearHereAfterSyncingToolLogs =>
      'Models appear here after syncing tool logs.';

  @override
  String get modelsUsed => 'Models used';

  @override
  String get mon2 => 'Mon';

  @override
  String get month => 'month';

  @override
  String get month2 => 'month';

  @override
  String get more => 'More';

  @override
  String moreActionsFor0(Object? name) => 'More actions for $name';

  @override
  String get mostTokensAreReusedContextWhichCosts =>
      'Most tokens are reused context, which costs much less when cached';

  @override
  String get mostUsed => 'Most used';

  @override
  String get mostlyPerRequest => 'Mostly per request';

  @override
  String get needsReview => 'Needs review';

  @override
  String get neverChecked => 'Never checked';

  @override
  String get neverCheckedAutomaticChecksOff =>
      'Never checked · Automatic checks off';

  @override
  String get neverRefreshed => 'Never refreshed';

  @override
  String get newArticlesWillAppearAfterTheNext =>
      'New articles will appear after the next refresh.';

  @override
  String get newInput => 'Input';

  @override
  String get newInputIsContentSentToThe =>
      'Input is new content sent to the model. Output is what the model returns. Cache read reuses matching context at a lower price. Cache write stores new context. These four categories do not overlap and add up to total usage.';

  @override
  String newVersion(Object? version) => 'New version $version';

  @override
  String get news => 'News';

  @override
  String newsItemsSummary(Object? count, Object? unreadSuffix) =>
      '$count ${_isOne(count) ? 'item' : 'items'}$unreadSuffix';

  @override
  String newsRefreshSummary(Object? count, Object? lastRefresh) =>
      '$count ${_isOne(count) ? 'source' : 'sources'} · $lastRefresh · Auto-refreshes every 30 min';

  @override
  String get noArticlesYet => 'No articles yet';

  @override
  String get noDailyRecords => 'No daily records';

  @override
  String get noHolidaysListed => 'No holidays listed';

  @override
  String get noIndividualRequestsInThisPeriod =>
      'No individual requests in this period';

  @override
  String get noIndividualRequestsInThisPeriodTools =>
      'No individual requests in this period. Tools that log only session totals do not appear here.';

  @override
  String get noListPrice => 'No list price';

  @override
  String get noLogsFoundForSupportedToolsOn =>
      'No logs found for supported tools on this computer. Install and use one of the supported tools, then come back.';

  @override
  String get noMatchingArticles => 'No matching articles';

  @override
  String get noModelsUsedYet => 'No models used yet';

  @override
  String get noPopularityDataForTheseResults =>
      'No popularity data for these results, so they cannot be sorted by popularity.';

  @override
  String get noPricingYet => 'No pricing yet';

  @override
  String get noProjectLogged => 'No project logged';

  @override
  String noReleaseCheckResult(Object? time) =>
      'No stable releases on GitHub yet · Checked $time';

  @override
  String get noRequestsInThisPeriodHaveTiming =>
      'No requests in this period have timing data.';

  @override
  String get noSessionsYet => 'No sessions yet';

  @override
  String get noStarredArticles => 'No starred articles';

  @override
  String get noSuccessfulRefreshYet => 'No successful refresh yet';

  @override
  String get noSyncHistory => 'No sync history';

  @override
  String get noSyncYet => 'No sync yet';

  @override
  String get noToolLogsFoundYet => 'No tool logs found yet';

  @override
  String get noUsage => ' · No usage';

  @override
  String get noUsage2 => 'No usage';

  @override
  String noUsageForPeriod(Object? label) => 'No usage for $label';

  @override
  String get noUsageMatchesTheseFiltersInThis =>
      'No usage matches these filters in this period.';

  @override
  String noUsageRecordedFor0ToCompare(Object? comparison) =>
      'No usage recorded for $comparison to compare.';

  @override
  String get noUsageYet => 'No usage yet';

  @override
  String get notLogged => 'Not logged';

  @override
  String get nothingIsCachedYetTheAppRefreshes =>
      'Nothing is cached yet. The app refreshes every 30 minutes while open, or you can refresh now.';

  @override
  String get numberUnits => 'Number units';

  @override
  String get offPeak => 'Off-peak';

  @override
  String get offPeakPricingAppliesAtOtherTimes =>
      'Off-peak pricing applies at other times and all day on listed holidays. Weekend make-up workdays use weekend pricing.';

  @override
  String offPeakSummary(Object? count) =>
      'Time-based pricing: $count off-peak ${_isOne(count) ? 'record' : 'records'}';

  @override
  String get official => 'Official';

  @override
  String get officialPrice => 'Official price';

  @override
  String get officialPricingPage => 'Official pricing page';

  @override
  String get offline => 'Offline';

  @override
  String get onDaysWithUsage => 'On days with usage';

  @override
  String get onePerRequest => ', one per request';

  @override
  String get oneRowPerRequestSelectARow =>
      'One row per request. Select a row to open its session.';

  @override
  String get onlyASessionTotalIsLoggedCounted =>
      'Only a session total is logged, counted on the start day';

  @override
  String openArticleInDefaultBrowser0(Object? title) =>
      'Open article in default browser: $title';

  @override
  String get openContainingFolder => 'Open containing folder';

  @override
  String get openDownloadPage => 'Open download page';

  @override
  String get openNavigationMenu => 'Open navigation menu';

  @override
  String get openingTheLocalNewsCache => 'Opening the local news cache…';

  @override
  String outOfDays(Object? elapsed) =>
      ' / $elapsed ${_isOne(elapsed) ? 'day' : 'days'}';

  @override
  String get output => 'Output';

  @override
  String get outputTokensDividedByTotalRequestTime =>
      'Output tokens divided by total request time. Including the wait usually makes this lower than Speed.';

  @override
  String get over100MillionTokensInOneRequest =>
      'Over 100 million tokens in one request';

  @override
  String get overview => 'Overview';

  @override
  String get overview2 => 'Overview';

  @override
  String get overviewComparisonEqualLink => 'as';

  @override
  String overviewComparisonLead(
    String period,
    String comparison,
    String relation,
  ) => 'Usage for $period was ';

  @override
  String get overviewComparisonOtherLink => 'than';

  @override
  String overviewComparisonTail(String relation, String comparison) =>
      ' $relation $comparison. ';

  @override
  String get overviewHigher => 'higher';

  @override
  String get overviewLower => 'lower';

  @override
  String get overviewMajorityLead => 'Most usage came from ';

  @override
  String get overviewMajorityTail => '';

  @override
  String get overviewMuchHigher => 'much higher';

  @override
  String get overviewMuchLower => 'much lower';

  @override
  String get overviewSecondToolLead => ', followed by ';

  @override
  String get overviewSentenceEnd => '.';

  @override
  String get overviewSimilar => 'about the same';

  @override
  String get overviewTopToolLead => 'The most-used tool was ';

  @override
  String overviewTrackingSince(String date) => 'Tracking since $date. ';

  @override
  String get pageNavigation => 'Page navigation';

  @override
  String get pastYear => 'Past year';

  @override
  String get peak => 'Peak';

  @override
  String get peakAndOffPeak => 'Peak and off-peak';

  @override
  String peakHourShare(Object? tokens, Object? share) =>
      '$tokens tokens, $share of today\'s usage';

  @override
  String get perMillionTokens => 'Per million tokens';

  @override
  String get perRequest => 'Per request';

  @override
  String get perRequest2 => 'Per request';

  @override
  String get perRequestEstimatesBasedOnLogTimestamps =>
      'Per-request estimates based on log timestamps.';

  @override
  String get perTurn => 'Per turn';

  @override
  String get period => 'Period';

  @override
  String get periodAllTime => 'all time';

  @override
  String periodUsage(Object? value) => 'Usage · $value';

  @override
  String get popular => 'Popular';

  @override
  String get priceUnavailable => 'Price unavailable';

  @override
  String get priceUnverified => 'Price unverified';

  @override
  String get pricing => 'Pricing';

  @override
  String get addPrice => 'Add price';

  @override
  String get manualPriceIntro =>
      'This model isn\'t in the price list. If you know its price, enter it here. It stays on this computer, is labeled Manual, and you can change or remove it anytime.';

  @override
  String manualPriceSubtitle(String model, String tool, String n) =>
      '$model · from $tool · $n records';

  @override
  String get copyPricesFrom => 'Copy prices from';

  @override
  String get copyPricesNone => 'None, enter manually';

  @override
  String get copyPricesHelp =>
      'Use this when it is another model under a different name, such as a provider-specific model ID.';

  @override
  String get copyBaseOnlyTag => 'Base price only';

  @override
  String copiedPriceSource(String id) => 'Same as $id list price';

  @override
  String get manualUsd => 'US dollar \$';

  @override
  String get manualCny => 'Chinese yuan ¥';

  @override
  String get manualOptional => 'Optional';

  @override
  String get manualNewInput => 'New input';

  @override
  String get manualCacheRead => 'Cache read';

  @override
  String get manualCacheWrite => 'Cache write';

  @override
  String get manualPriceUnit =>
      'Prices per million tokens. Leave optional fields blank to add no cost for those tokens.';

  @override
  String get manualSource => 'Source';

  @override
  String get manualSourceHint => 'Pricing page URL or a note';

  @override
  String manualEstimatePending(String n) =>
      'Enter input and output prices to see the total for these $n records.';

  @override
  String manualEstimate(String n, String amount, String parts) =>
      'After saving, these $n records are priced at this rate: about $amount${parts.isEmpty ? '' : ' ($parts)'}.';

  @override
  String get manualNoCacheRead =>
      'Cache read is blank, so those tokens add no cost.';

  @override
  String manualSavedAtRate(String rate) =>
      'Saved in US dollars at 1 USD ≈ $rate CNY; later rate changes do not apply.';

  @override
  String get manualPriceFootnote =>
      'If the price list adds this model later, your price still applies and you\'ll be offered the list price.';

  @override
  String get manualPriceRequired => 'Enter input and output prices.';

  @override
  String get manualPriceNonnegative => 'Prices must be 0 or more.';

  @override
  String get saveManual => 'Save';

  @override
  String get manualBadge => 'Manual';

  @override
  String get manualBadgeTooltip => 'Priced with your manual price';

  @override
  String get manualPriceState => 'Your own prices, kept on this computer';

  @override
  String unpricedFillHelp(String n) =>
      'If you know its price, add it and these $n records get a cost.';

  @override
  String manualPriceCreated(String date) =>
      'You entered this price on $date; it stays on this computer.';

  @override
  String manualConverted(String rate) =>
      'Converted to US dollars at 1 USD ≈ $rate CNY.';

  @override
  String manualSourceNote(String note) => 'Source: $note';

  @override
  String get editManualPrice => 'Edit';

  @override
  String get removeManualPrice => 'Remove manual price';

  @override
  String get removeManualTitle => 'Remove manual price?';

  @override
  String removeManualBody(String model, String n) =>
      'After removal, the $n records of $model go back to Unpriced and add no cost.';

  @override
  String get removeManualConfirm => 'Remove';

  @override
  String manualListPrice(String input, String output) =>
      'The price list now has an official price for this model ($input in · $output out). Your manual price still applies.';

  @override
  String get useListPrice => 'Use list price';

  @override
  String pricingCatalogRow(String date, String source) =>
      'Price list: $date · $source';

  @override
  String get pricingCatalogOnline => 'Updated online';

  @override
  String get pricingCatalogBuiltin => 'Built-in';

  @override
  String pricingCatalogManual(String n) => '$n manual';

  @override
  String get pricingOnlineSettings => 'Online update settings ›';

  @override
  String get addMissingPrices => 'Add missing prices ›';

  @override
  String get autoUpdatePricingLabel => 'Update price list automatically';

  @override
  String get autoUpdatePricingHelp =>
      'Once a day, downloads this project\'s checked price list from raw.githubusercontent.com. Nothing is uploaded. Turn off to use only the built-in list.';

  @override
  String pricingUsingDate(String date) => 'Using the $date price list';

  @override
  String pricingCheckedAt(String time) => 'Checked $time';

  @override
  String get pricingUpdateNow => 'Update now';

  @override
  String get pricingChecking => 'Checking…';

  @override
  String pricingUpdated(String date, String n) =>
      'Updated to the $date list. $n models newly priced; past amounts recalculated.';

  @override
  String pricingUpdatedNoNew(String date) =>
      'Updated to the $date list; past amounts recalculated.';

  @override
  String get pricingOffline => 'Couldn\'t update: GitHub is unreachable.';

  @override
  String get pricingLimited =>
      'Couldn\'t update: GitHub refused the request for now.';

  @override
  String get pricingInvalid =>
      'Couldn\'t update: the downloaded price list couldn\'t be read.';

  @override
  String pricingStillUsing(String date) =>
      'Still using the $date list; will try again tomorrow.';

  @override
  String pricingDisabled(String date) =>
      'Using only the built-in $date price list.';

  @override
  String pricingAboutOnline(String date, String version, String builtin) =>
      'Online $date · $version (built-in $builtin)';

  @override
  String pricingAboutBuiltin(String date, String version) =>
      'Built-in $date · $version';

  @override
  String get pricingIsUnavailableForThisModel =>
      'Pricing is unavailable for this model';

  @override
  String get pricingIsUnpublishedOrUnverifiedEstimatedFrom =>
      'Pricing is unpublished or unverified. Estimated from similar models.';

  @override
  String get pricingSettings => 'Pricing & settings';

  @override
  String get pricingVersion => 'Pricing version';

  @override
  String get project => 'Project';

  @override
  String prompt0Tokens(Object? count) => 'Prompt > $count tokens';

  @override
  String get promptLengthIncludesNewInputCacheReads =>
      'Prompt length includes input, cache reads and cache writes. The lower tier applies at the exact threshold. Session snapshots use the base tier. When prompt length is incomplete and the known part stays within the threshold, the base tier applies and is flagged.';

  @override
  String get pts => 'pts';

  @override
  String publishedAt0(Object? value) => 'Published at $value';

  @override
  String publishedOn0(Object? value) => 'Published on $value';

  @override
  String get rankedByThisSource => 'Ranked by this source';

  @override
  String get rateLimited => 'Rate limited';

  @override
  String rateLimitedUpdateCheck(Object? time) =>
      'GitHub rate-limited this network · $time. Try again later.';

  @override
  String rateUpdatedAt(int month, int day, String hour, String minute) =>
      'Updated ${calendarDay(month, day)}, $hour:$minute';

  @override
  String get readAndStarredStatusUnavailable =>
      'Read and starred status unavailable';

  @override
  String get reading => 'Reading…';

  @override
  String get readingLogs => 'Reading logs…';

  @override
  String onboardingReading(int read, int total) =>
      'Reading logs… $read of $total files';

  @override
  String get onboardingOrganizing =>
      'All logs read. Putting the numbers together…';

  @override
  String onboardingElapsed(int minutes, int seconds) =>
      '$minutes min $seconds s elapsed';

  @override
  String get onboardingTimeHint =>
      'With lots of logs, the first count may take a few minutes. After that, only new entries are read, so it\'s much faster.';

  @override
  String get onboardingToolDone => 'Done';

  @override
  String onboardingToolReading(int read, int total) =>
      'Reading $read of $total';

  @override
  String get onboardingToolWaiting => 'Waiting';

  @override
  String get onboardingContinueHint =>
      'No need to wait: look around while counting continues in the background. If you close the window, it picks up where it left off next time.';

  @override
  String get readsLogsOnThisComputerAndLeaves =>
      'Reads logs on this computer and leaves the tools unchanged. No uploads.';

  @override
  String get recentSessions => 'Recent sessions';

  @override
  String recordCount(Object? count) =>
      '$count ${_isOne(count) ? 'record' : 'records'}';

  @override
  String get recordType => 'Record type';

  @override
  String get records => 'Records';

  @override
  String get recordsComplete => 'Records complete';

  @override
  String recordsNoun(int count) => _isOne(count) ? 'record' : 'records';

  @override
  String recordsProcessed(
    Object? attempted,
    Object? inserted,
    Object? updated,
    Object? unchanged,
    Object? rejected,
  ) =>
      'Processed $attempted ${_isOne(attempted) ? 'record' : 'records'}. Added $inserted, updated $updated, unchanged $unchanged, skipped $rejected.';

  @override
  String get recordsWithoutPricesAreExcludedFromCost =>
      'Unpriced records are excluded from cost. See which models in Pricing & settings.';

  @override
  String get refreshAll => 'Refresh all';

  @override
  String get refreshCanceled => 'Refresh canceled';

  @override
  String get refreshFailedShowingCachedNews =>
      'Refresh failed · Showing cached news';

  @override
  String get refreshFailedTryAgainShortly =>
      'Refresh failed. Try again shortly.';

  @override
  String get refreshNow => 'Refresh now';

  @override
  String refreshProgress(Object? completed, Object? total) =>
      'Refreshing · $completed/$total sources done';

  @override
  String get refreshThisSource => 'Refresh this source';

  @override
  String refreshed0(Object? value) => 'Refreshed $value';

  @override
  String get refreshesEvery30MinutesWhileOpenRate =>
      'Refreshes every 30 minutes while open. Rate-limited sources skip the next refresh.';

  @override
  String get refreshing => 'Refreshing';

  @override
  String get refreshing2 => 'Refreshing…';

  @override
  String get release => 'Release';

  @override
  String releaseDatePrefix(Object? value) => 'Released $value · ';

  @override
  String remainingTools(Object? value1, Object? value2) =>
      '$value1 more · $value2 total';

  @override
  String remove0Filter(Object? label) => 'Remove $label filter';

  @override
  String requestCount(Object? value) =>
      '$value ${_isOne(value) ? 'request' : 'requests'}';

  @override
  String requestCountSuffix(int count) =>
      ' ${_isOne(count) ? 'request' : 'requests'}';

  @override
  String get requestFailed => 'Request failed';

  @override
  String requestFailed0(Object? failure) => 'Request failed: $failure';

  @override
  String get requests => 'Requests';

  @override
  String requests0(Object? periodLabel) => 'Requests · $periodLabel';

  @override
  String get rereadAllLogs => 'Reread all logs';

  @override
  String get rereadAllLogsWithoutUsingThePrevious =>
      'Reread all logs without using the previous results. Use this if usage is missing or seems wrong. Existing ledger records are kept.';

  @override
  String get rereading => 'Rereading…';

  @override
  String get responseTooLarge => 'Response too large';

  @override
  String get retry => 'Retry';

  @override
  String get retryLoading => 'Retry loading';

  @override
  String retryingAt0(Object? value) => 'Retrying at $value';

  @override
  String reviewableRecords(Object? value) =>
      '$value ${_isOne(value) ? 'record can' : 'records can'} be checked against the original logs';

  @override
  String get sat2 => 'Sat';

  @override
  String savedTo0(Object? exportPath) => 'Saved to: $exportPath';

  @override
  String get scanAgain => 'Scan again';

  @override
  String get schemaVersion => 'Schema version';

  @override
  String get scrollableTableOfConditionalPrices =>
      'Scrollable table of conditional prices';

  @override
  String get searchTitlesAndSummaries => 'Search articles';

  @override
  String secondsDuration(Object? value) => '$value s';

  @override
  String get seeHowManyTokensYourAiCoding =>
      'See how many tokens your AI coding tools used and what they would cost at list prices.';

  @override
  String selectABarForThat0S(Object? unit) =>
      '. Select a bar for that $unit\'s breakdown';

  @override
  String selectABarToFilterToThat(Object? unit) =>
      '. Select a bar to filter to that $unit';

  @override
  String get selectARowForCachePricesAnd =>
      'Select a row for cache prices and details. The built-in pricing table works offline.';

  @override
  String get selectARowToAddItTo => 'Select a row to add it to the filters';

  @override
  String get selectTheStarNextToAnArticle =>
      'Select the star next to an article to save it. Starred articles stay here after the source removes them.';

  @override
  String selectToViewThis0SBreakdown(Object? value) =>
      'Select to view this $value\'s breakdown';

  @override
  String get selectedPeriod => 'Selected period';

  @override
  String get selectedPeriodInSentence => 'the selected period';

  @override
  String get sentenceSeparator => '; ';

  @override
  String get session => 'Session';

  @override
  String get sessionDetails => 'Session details';

  @override
  String sessionForTool(String tool) => '$tool session';

  @override
  String sessionHeading(
    Object? tool,
    Object? date,
    Object? time,
    Object? duration,
  ) => '$tool · Started $date $time · $duration';

  @override
  String get sessionId => 'Session ID';

  @override
  String sessionRecordSummary(Object? count, Object? description) =>
      '$count ${_isOne(count) ? 'record' : 'records'}$description';

  @override
  String get sessionSnapshotBaseTier => 'Session snapshot · Base tier';

  @override
  String sessionSpan(Object? duration, Object? days) =>
      '$duration · Over $days ${_isOne(days) ? 'day' : 'days'}';

  @override
  String get sessionTotalsOnly => 'Session totals only';

  @override
  String get sessionTotalsOnly2 => 'Session totals only';

  @override
  String get sessionUnavailable => 'Session unavailable';

  @override
  String get sessionUsageIsAvailableRequestTimesAre =>
      'Session usage is available. Request times are unavailable.';

  @override
  String get sessions => 'Sessions';

  @override
  String sessions0(Object? value) => 'Sessions · $value';

  @override
  String get sessionsNavigation => 'Sessions';

  @override
  String get sessionsAppearHereAfterSyncingToolLogs =>
      'Sessions appear here after syncing tool logs.';

  @override
  String get sessionsMixingBothRecordTypes =>
      'Sessions mixing both record types';

  @override
  String sessionsNoun(int count) => _isOne(count) ? 'session' : 'sessions';

  @override
  String sessionsWithUsageIn0SortedBy(Object? periodLabel) =>
      'Sessions with usage ($periodLabel), sorted by usage in that period. Totals cover the full session.';

  @override
  String get settings => 'Settings';

  @override
  String get share => 'Share';

  @override
  String get shareOfInputServedFromCache => 'Share of input served from cache';

  @override
  String shortMonth(int month) => const [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ][month - 1];

  @override
  String shortWeekday(int weekday) =>
      const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][weekday - 1];

  @override
  String show0More(Object? value) => 'Show $value more';

  @override
  String show30More0Left(Object? value) => 'Show 30 more ($value left)';

  @override
  String showing0Session(Object? count) =>
      'Showing $count ${_isOne(count) ? 'session' : 'sessions'}';

  @override
  String skipped0FileFromToolsWithNo(Object? skippedFiles) =>
      'Skipped $skippedFiles ${_isOne(skippedFiles) ? 'file' : 'files'} from tools with no changes.';

  @override
  String get slowerThan90OfRequestsHere => 'Slower than 90% of requests here';

  @override
  String get someSessionsHaveOnlyATotalAnd =>
      'Some sessions have only a total and no timeline.';

  @override
  String get sort => 'Sort';

  @override
  String sortBy0(Object? value) => 'Sort by ${_lowerInitial('$value')}';

  String _lowerInitial(String value) =>
      value.isEmpty ? value : value[0].toLowerCase() + value.substring(1);

  @override
  String sortedBy0HighestFirstItemsWithout(Object? unit) =>
      'Sorted by $unit, highest first. Items without a score come last. Ties are sorted by date.';

  @override
  String get sortedByUsageInThisPeriod => 'Sorted by usage in this period';

  @override
  String get source => 'Source';

  @override
  String source0(Object? sourceName) => 'Source $sourceName';

  @override
  String sourceCheckLabel(String check, String count) => '$check: $count';

  @override
  String sourceCheckRecordCount(int count) =>
      '$count ${_isOne(count) ? 'record' : 'records'}';

  @override
  String sourceCheckSessionCount(int count) =>
      '$count ${_isOne(count) ? 'session' : 'sessions'}';

  @override
  String get sourceId => 'Source ID';

  @override
  String sourceRecordCount(Object? value) =>
      '$value ${_isOne(value) ? 'record' : 'records'}';

  @override
  String sourcesIntro(Object? found) =>
      '${found}Token Lens reads local logs only, uploads nothing and leaves tools unchanged.';

  @override
  String sourcesNotUpdated(Object? failed) =>
      '$failed ${_isOne(failed) ? 'source' : 'sources'} did not update';

  @override
  String get speed => 'Speed';

  @override
  String get speed2 => 'Speed ';

  @override
  String get speedTokenS => 'Speed (tokens/s)';

  @override
  String get speedTokensPerSecondWhileReplying =>
      'Speed (tokens per second while replying)';

  @override
  String get star => 'Star';

  @override
  String get starred => 'Starred';

  @override
  String starred0(Object? starred) => 'Starred $starred';

  @override
  String get stars => 'stars';

  @override
  String get start => 'Start';

  @override
  String get startCounting => 'Start counting';

  @override
  String sessionStartLabel(Object? value) => 'Started $value';

  @override
  String startedOn(String date) => 'Started $date';

  @override
  String get status => 'Status';

  @override
  String get stillUpLate => 'Still up late?';

  @override
  String get subscription => 'Subscription';

  @override
  String get subscriptionsAreBilledSeparately =>
      ' Subscriptions are billed separately.';

  @override
  String get sun2 => 'Sun';

  @override
  String get supported => 'Ready';

  @override
  String supportedToolCount(Object? supported) => '$supported supported';

  @override
  String supportedToolsMissing(Object? missingCount) =>
      '$missingCount supported ${_isOne(missingCount) ? 'tool' : 'tools'} not found on this computer';

  @override
  String get syncComplete => 'Sync complete';

  @override
  String syncCompleted(
    Object? files,
    Object? reused,
    Object? inserted,
    Object? updated,
    Object? seconds,
  ) =>
      'Sync complete. Scanned $files ${_isOne(files) ? 'file' : 'files'}, ${reused}added $inserted, updated $updated in $seconds s.';

  @override
  String syncFailed0(Object? error) => 'Sync failed: $error';

  @override
  String get syncFailedPreviouslyCollectedDataIsStill =>
      'Sync failed. Previously collected data is still available.';

  @override
  String syncFinishedWithWarnings(Object? warning) =>
      'Sync finished with warnings: $warning';

  @override
  String get syncNow => 'Sync now';

  @override
  String get syncUsage => 'Sync usage';

  @override
  String syncedHoursAgo(Object? hours) => 'Synced $hours hr ago';

  @override
  String syncedMinutesAgo(Object? minutes) => 'Synced $minutes min ago';

  @override
  String synced0NoIssues(Object? value) => 'Synced $value · No issues';

  @override
  String syncedDaysAgo(Object? days) =>
      'Synced ${_isOne(days) ? 'yesterday' : '$days days ago'}';

  @override
  String get syncedJustNow => 'Synced just now';

  @override
  String get syncing => 'Syncing…';

  @override
  String get syncing2 => 'Syncing…';

  @override
  String get syncing3 => 'Syncing';

  @override
  String tableSpanningSessions(
    Object? tokens,
    Object? spanUnit,
    Object? bucketUnit,
  ) =>
      'Totals above include $tokens tokens from session snapshots spanning more than one $spanUnit. Their usage cannot be split by $bucketUnit, so the table omits them.';

  @override
  String get technicalDetails => 'Technical details';

  @override
  String get technicalNotes => 'Technical notes';

  @override
  String thisHourSoFar(Object? hour, Object? comparison) =>
      '$hour:00 to now$comparison';

  @override
  String builtInVersion(Object? value) => '$value · Built-in';

  @override
  String toolDidNotLogGenerationTime(Object? tool) =>
      '$tool did not log generation time.';

  @override
  String toolDidNotLogFirstTokenTime(Object? tool) =>
      '$tool did not log time to first token.';

  @override
  String lastSyncReadFailures(Object? failures) =>
      '$failures read ${_isOne(failures) ? 'failure' : 'failures'} in the last sync. Other data was updated';

  @override
  String filteredPeriod(Object? value) => '$value (filtered)';

  @override
  String fractionalHours(Object? value) => '$value hr';

  @override
  String hoursAgo(Object? hours) => '$hours hr ago';

  @override
  String updateAvailable(Object? latest) => '$latest is available';

  @override
  String onlyVersionSoFar(Object? current) =>
      '$current is the only version so far';

  @override
  String upToDate(Object? current) => '$current is up to date';

  @override
  String sourceStatusWithLastRefresh(Object? status, Object? lastSuccess) =>
      '$status · Last successful refresh $lastSuccess';

  @override
  String averageSpeedIncludesWait(Object? tool) =>
      '$tool logged total request time only. Average speed includes the wait.';

  @override
  String roundedMinutes(Object? value) => '$value min';

  @override
  String minutesAgo(Object? minutes) => '$minutes min ago';

  @override
  String additionalNewsSources(Object? count) =>
      '$count more ${_isOne(count) ? 'source' : 'sources'}';

  @override
  String cacheInputShare(Object? value) => '$value of input hit the cache';

  @override
  String shareOfTotal(Object? value) => '$value of total';

  @override
  String sessionTotalsOnlyForTool(Object? name) =>
      '$name logs only session totals. Usage counts on the start day, since there are no request times for a daily breakdown.';

  @override
  String peakHoursInTimeZone(Object? value) =>
      '$value. Peak hours below exclude the end time:';

  @override
  String sourceMonthlyTokens(Object? tokens) => '$tokens tokens this month · ';

  @override
  String partiallyUnreadSuffix(Object? unread) => ', $unread unread';

  @override
  String get chineseNumberUnits => '万 / 亿';

  @override
  String get englishNumberExample => '1.82B tokens · 37.0M tokens';

  @override
  String get chineseNumberExample => '18.2亿 tokens · 3700万 tokens';

  @override
  String get theAppWillTryAgainTomorrowYou =>
      'The app will try again tomorrow. You can also retry now.';

  @override
  String get theClientDidNotReportThisField =>
      'The client did not report this field';

  @override
  String get theEarliestRecord => 'the earliest record';

  @override
  String theFirstRecordIsFrom0Older(Object? firstSeenText) =>
      'The first record is from $firstSeenText. Older usage is unavailable because the tools no longer keep those logs. New usage is picked up automatically each time you open the app.';

  @override
  String get theLastSyncDidNotFinish => 'The last sync did not finish.';

  @override
  String get lastSyncIncomplete => 'The last sync did not finish';

  @override
  String get recentSyncIncomplete => 'The last sync did not finish';

  @override
  String get theLocalCacheIsUnavailableTryRefreshing =>
      'The local cache is unavailable. Try refreshing.';

  @override
  String get theLogDidNotRecordThisField =>
      'The log did not record this field.';

  @override
  String get theLogHasNoSessionIdFor =>
      'The log has no session ID for this request, so its session cannot be opened.';

  @override
  String get theResponseExceededTheSizeLimitCached =>
      'The response exceeded the size limit. Cached articles are unchanged.';

  @override
  String get theSameTimeYesterday => 'the same time yesterday';

  @override
  String get theSourceDidNotProvideAPublication =>
      'The source did not provide a publication time';

  @override
  String get theSourceIsRateLimitingRequestsIt =>
      'The source is rate-limiting requests. It will be skipped on the next automatic refresh.';

  @override
  String get theSourceIsUnavailableTryAgainShortly =>
      'The source is unavailable. Try again shortly.';

  @override
  String get theSourceReturnedAnUnsupportedFormatCached =>
      'The source returned an unsupported format. Cached articles are unchanged.';

  @override
  String get theSourceTimedOutTryAgainShortly =>
      'The source timed out. Try again shortly.';

  @override
  String get theToolDidNotLogThis => 'The tool did not log this';

  @override
  String get theWaitTimedOutSyncMayStill =>
      'The wait timed out. Sync may still be running';

  @override
  String themeShortcut(Object? value) =>
      '$value. Press and hold to follow system';

  @override
  String get thereAreNoPricesForTheModels =>
      'There are no prices for the models used in this period';

  @override
  String theseResultsUse0PopularityScoresUse(Object? units) =>
      'These results use $units. Scores in different units cannot be compared.';

  @override
  String get thisCodexRequestBeganWithATool =>
      'This Codex request began with a tool call, so its first output time is unavailable.';

  @override
  String get thisHour => 'This hour';

  @override
  String get thisMonth => 'This month';

  @override
  String get thisMonth2 => 'This month';

  @override
  String get thisRequestDidNotFinishNormallySo =>
      'This request did not finish normally, so speed is unavailable.';

  @override
  String get thisSessionMayNoLongerBeIn =>
      'This session may no longer be in the ledger.';

  @override
  String get thisToolLogsOneTotalPerSession =>
      ' (this tool logs one total per session)';

  @override
  String get thisToolLogsTimingForAWhole =>
      'This tool logs timing for a whole turn, which may contain several requests.';

  @override
  String get thisToolLogsTimingForAWhole2 =>
      'This tool logs timing for a whole turn, which may contain several requests. Its timing is not directly comparable to per-request timings.';

  @override
  String get thisWeek => 'This week';

  @override
  String get thisWeek2 => 'This week';

  @override
  String get thisYearSTotal => 'This year\'s total';

  @override
  String get thu2 => 'Thu';

  @override
  String get tier => 'Tier';

  @override
  String get time => 'Time';

  @override
  String get timeFromSendingTheRequestToThe =>
      'Time from sending the request to the first output, including reasoning. Half of requests finish this wait within the typical time and 90% within the slow time.';

  @override
  String get timeOutsideExpectedRange => 'Time outside expected range';

  @override
  String get timeUnavailable => 'Time unavailable';

  @override
  String get timedOnly => 'Timed only';

  @override
  String get timedOut => 'Timed out';

  @override
  String timedRequestCoverage(Object? requests, Object? recorded) =>
      '$recorded of $requests requests recorded';

  @override
  String moreTimingEstimates(int count) =>
      '· $count more ${count == 1 ? 'estimate' : 'estimates'}';

  @override
  String get timingReportedByTheClient => 'Timing reported by the client';

  @override
  String get to => 'To';

  @override
  String get today => 'Today';

  @override
  String today0(Object? base) => 'Today · $base';

  @override
  String get tokenBreakdown => 'Token breakdown';

  @override
  String get tokenLensOnlyReadsLogFilesCheck =>
      'Token Lens only reads log files and never modifies them. Check read permissions for this folder, then select Sync now.';

  @override
  String get tokenLensReadsAiCodingToolLogs =>
      'Token Lens reads AI coding tool logs. See which tools it found under Tools, or sync now.';

  @override
  String get tokenLensSyncsOnceEachTimeIt =>
      'Token Lens syncs once each time it opens. You can also sync manually.';

  @override
  String get tokensCountTowardUsageTheirCostIs =>
      'Tokens count toward usage. Their cost is excluded.';

  @override
  String get tokensGeneratedPerSecondAfterOutputBegins =>
      'Tokens generated per second after output begins.';

  @override
  String get tokenUnit => 'tokens';

  @override
  String get tool => 'Tool';

  @override
  String get toolSources => 'Tools';

  @override
  String get toolUpdates => 'Tool updates';

  @override
  String get tools => 'Tools';

  @override
  String toolsFound(Object? count) =>
      'Found $count ${_isOne(count) ? 'tool' : 'tools'} on this computer';

  @override
  String toolsFoundOnComputer(Object? count) =>
      'Found $count AI coding ${_isOne(count) ? 'tool' : 'tools'} on this computer. ';

  @override
  String get toolsInThisPeriod => 'Tools in this period';

  @override
  String get toolsThatLogOnlySessionTotalsHave =>
      'Tools that log only session totals have no individual requests to show here.';

  @override
  String topFiveModels(Object? value) => 'Top 5 · $value';

  @override
  String get topModels => 'Top models';

  @override
  String get total => 'Total';

  @override
  String total0(Object? value) => 'Total $value';

  @override
  String total01(Object? value1, Object? value2) => 'Total $value1 · $value2';

  @override
  String get totalEstCost => 'Total est. cost';

  @override
  String get totalRequests => 'Total requests';

  @override
  String get totalSoFar => 'Total so far';

  @override
  String get totalUsage => 'Total usage';

  @override
  String get trend => 'Trend';

  @override
  String trendAxisLabels(Object? labels) => 'Trend axis: $labels';

  @override
  String get trendChartFocusItAndUseThe =>
      'Trend chart: Focus it and use the arrow keys to inspect each period';

  @override
  String get trendChartFocusItAndUseThe2 =>
      'Trend chart: Focus it and use the arrow keys to inspect each period. Press Enter for that period\'s breakdown';

  @override
  String trendWithAverageHint(Object? unit, Object? actionHint) =>
      'Usage by $unit, colored by tool. Dashed line shows the average$actionHint';

  @override
  String trendingItemLabel(
    Object? rank,
    Object? title,
    Object? score,
    Object? unit,
  ) => 'Trending #$rank: $title, $score $unit';

  @override
  String get trendingNow => 'Trending now';

  @override
  String get trendingSources => 'Trending sources';

  @override
  String get tryAnotherCategorySourceTypeOrSearch =>
      'Try another category, source, type or search term.';

  @override
  String get tryAnotherFilter => 'Try another filter.';

  @override
  String get tue2 => 'Tue';

  @override
  String get type => 'Type';

  @override
  String typicalAndSlowTiming(Object? typical, Object? slow) =>
      'Typical $typical s, slow $slow s';

  @override
  String unchangedFiles(Object? reused) => 'reused $reused unchanged, ';

  @override
  String get unknownModel => 'Unknown model';

  @override
  String get unknownTime => 'Unknown time';

  @override
  String get unknownTimingSource => 'Unknown timing source';

  @override
  String get unmarked => 'Unmarked';

  @override
  String get unpriced => 'Unpriced';

  @override
  String get unpricedBecauseTheModelIsMissing =>
      'Unpriced because the model is missing';

  @override
  String unreachableUpdateCheck(Object? checked, Object? retry) =>
      'Could not reach GitHub · $checked. $retry';

  @override
  String get unread => 'Unread';

  @override
  String unread0(Object? unread) => 'Unread $unread';

  @override
  String unreadCount(Object? count) => '$count unread';

  @override
  String get unstar => 'Unstar';

  @override
  String get unsupportedFormat => 'Unsupported format';

  @override
  String get upcoming => ' · Upcoming';

  @override
  String get upcoming2 => 'Upcoming';

  @override
  String updateAvailableDetails(Object? released, Object? version) =>
      '${released}You\'re using $version';

  @override
  String get updateCheckFailed => 'Update check failed';

  @override
  String get updateRate => 'Update rate';

  @override
  String get updates => 'Updates';

  @override
  String get updating => 'Updating…';

  @override
  String get upvotes => 'upvotes';

  @override
  String get usage => 'Usage';

  @override
  String get usageAppearsHereAfterTheToolWrites =>
      'Usage appears here after the tool writes it to its logs. Try another date range or check back after using a tool.';

  @override
  String get usageBreakdown => 'Usage breakdown';

  @override
  String get usageByTool => 'Usage by tool';

  @override
  String get usageIsCountedWhenEachRecordOccurred =>
      'Usage is counted when each record occurred. For tools that log only session totals, usage counts on the start day and request counts are unavailable.';

  @override
  String get usageIsReady => 'Usage is ready';

  @override
  String get usageOverview => 'Usage overview';

  @override
  String get usageReflectsTheFiltersSessionTotalsCover =>
      'Usage reflects the filters. Session totals cover the full session and are not affected by filters.';

  @override
  String usageTrendHint(Object? unit, Object? actionHint) =>
      'Usage by $unit, colored by tool$actionHint';

  @override
  String get usd => 'USD \$';

  @override
  String get usdMillionTokensADashMeansNo =>
      'USD / million tokens · A dash means no separate price';

  @override
  String get useASupportedAiCodingToolThen =>
      'Use a supported AI coding tool, then select Sync now.';

  @override
  String get verifiedAgainstTheProviderSPricingPage =>
      'Verified against the provider\'s pricing page';

  @override
  String get verifiedWithRealLogs => 'Real logs';

  @override
  String get version => 'Version';

  @override
  String get view => 'View';

  @override
  String view0InBreakdown(Object? value) => 'View $value in breakdown';

  @override
  String get view2 => 'View';

  @override
  String get viewAll => 'View all';

  @override
  String get viewAllSessions => 'View all sessions';

  @override
  String get viewBreakdown => 'View breakdown';

  @override
  String get viewDetails => 'View details';

  @override
  String viewSession01(Object? session, Object? tool) =>
      'View session: $session, $tool';

  @override
  String get viewThisMonth => 'View this month';

  @override
  String get viewToolSources => 'View tools';

  @override
  String get viewUpdateDetails => 'View update details';

  @override
  String get viewUsage => 'View usage';

  @override
  String get sourceViewUsage => 'View usage';

  @override
  String vs0(Object? comparison) => 'vs. ${'$comparison'.toLowerCase()}';

  @override
  String get vsThisTimeYesterday => ', vs. this time yesterday';

  @override
  String get wed2 => 'Wed';

  @override
  String get weightedByTime => 'Weighted by time';

  @override
  String get welcomeToTokenLens => 'Welcome to Token Lens';

  @override
  String get whenRepeatedContextHitsTheCacheIt =>
      'When repeated context hits the cache, it is billed at the cache rate instead of the input rate. Savings are the difference, estimated at list prices.';

  @override
  String get whereTheTokensWent => 'Where the tokens went';

  @override
  String get withUsageInThisPeriod => 'With usage in this period';

  @override
  String get workingDirectory => 'Working directory';

  @override
  String yearActiveDaysAndStreakTail(int activeDays, int streak) =>
      ' ${_isOne(activeDays) ? 'day' : 'days'}, longest streak $streak ${_isOne(streak) ? 'day' : 'days'}';

  @override
  String yearActiveDaysTail(int activeDays) =>
      ' ${_isOne(activeDays) ? 'day' : 'days'}';

  @override
  String get yearActivityLead => 'Active in the past year: ';

  @override
  String yearNewcomerLead(String date) => 'Tracking since $date. Active: ';

  @override
  String get yesterday => 'Yesterday';

  @override
  String yesterday0(Object? base) => 'Yesterday · $base';

  @override
  String get youCanRetryNow => 'You can retry now.';

  @override
  String currentVersion(Object? current) => 'You\'re using $current';
}
