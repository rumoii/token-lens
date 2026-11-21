import 'package:flutter/widgets.dart';

import '../startup_failure.dart';

part 'strings_en.dart';
part 'strings_zh.dart';

const englishStrings = EnglishStrings();
const chineseStrings = ChineseStrings();

AppStrings resolveStrings(String language, String systemLanguage) =>
    switch (language) {
      'zh' => chineseStrings,
      'en' => englishStrings,
      _ =>
        systemLanguage.toLowerCase().startsWith('zh')
            ? chineseStrings
            : englishStrings,
    };

class AppLanguageScope extends InheritedWidget {
  const AppLanguageScope({
    super.key,
    required this.strings,
    required super.child,
  });

  final AppStrings strings;

  @override
  bool updateShouldNotify(AppLanguageScope oldWidget) =>
      strings != oldWidget.strings;
}

extension AppStringsContext on BuildContext {
  AppStrings get strings =>
      dependOnInheritedWidgetOfExactType<AppLanguageScope>()?.strings ??
      chineseStrings;
}

typedef StartupFailureCopy = ({String title, String body, List<String> steps});

abstract class AppStrings {
  String get miniWindow;
  String get miniPin;
  String get miniUnpin;
  String get miniSettings;
  String get miniExpand;
  String miniEstimate(String amount);
  String miniInterval(int seconds);
  String miniUpdated(int age, int interval);
  String get miniSyncFailed;
  String get miniProjects;
  String miniTopProjects(int count);
  String get miniAllProjects;
  String miniLatest(int count);
  String miniMoreProjects(int count);
  String get miniActiveModels;
  String miniMoreModels(int count);
  String miniApproxSpeed(String value);
  String miniUntimedModel(String tool);
  String miniOutput(String value);
  String miniFirstToken(String seconds);
  String miniHour(int hour);
  String get miniNoUsage;
  String get miniNoRequests;
  String get miniNoModels;
  String get miniChartRange;
  String miniChartChoice(int minutes);
  String get miniChartNow;
  String miniChartTip(String time, String usage, bool current);
  String miniChartLabel(int minutes);
  String get miniRefreshEvery;
  String get miniProjectsShown;
  String miniProjectsChoice(int count);
  String get miniSwitchFailed;

  StartupFailureCopy startupFailureCopy(StartupFailure failure);
  String get startupOpenLogFolder;
  String get startupOpenAppFolder;
  String get startupExportFailureHelp;
  String get startupExportDestinationUnavailable;
  String get startupDiagnosticsPrivacy;
  String get startupPrivacyWithoutCore;
  String get startupDetails;
  String get startupErrorCode;
  String get startupDataFolder;
  String get startupMessage;
  String get startupStatisticsUnavailable;
  String get startupNewsStillWorks;
  String get startupOverview;
  String get startupDetail;
  String get startupSessions;
  String get morePeriods;
  String get lastSevenDays;
  String get lastThirtyDays;
  String get lastSevenDaysInSentence;
  String get lastThirtyDaysInSentence;
  String get dayBeforeYesterday;
  String get weekBeforeLast;
  String get monthBeforeLast;
  String get previousSevenDays;
  String get previousThirtyDays;
  String comparisonDates(String current, int n, String previous, int m);
  String comparisonDateRanges(String current, String previous);
  String get sessionSearch;
  String get spansPeriod;
  String get copySessionId;
  String get sessionIdCopied;
  String heatTokenRange(String from, String to);
  String heatTokensAndAbove(String from);
  String discoveredLogTools(int count);
  String discoveredLogFiles(int count);
  String moreDiscoveredTools(int count);
  String get noSupportedToolsDiscovered;
  String get completionByTool;
  String completionToolCount(int count);
  String otherCompletionTools(int count);
  String completionTokenEstimate(String cost);
  String noMatchingSessions(String q);
  String get clearSessionSearch;
  String get sessionSortCost;
  String get sessionSortStarted;
  String get sessionSortRecent;
  String get sessionSortRequests;
  String get sortDescending;
  String get sortAscending;
  String sortedSessions(String period, String sort);
  String sessionSortUsageInSentence(String periodLabel);
  String get sessionSortCostInSentence;
  String get sessionSortStartedInSentence;
  String get sessionSortRecentInSentence;
  String get sessionSortRequestsInSentence;
  String get filterSearch;
  String get noMatchingOptions;
  String get seeWhatChanged;
  String get whatChangedFromPrevious;
  String get comparisonCurrent;
  String get comparisonPrevious;
  String get comparisonChange;
  String get sortedBySizeOfChange;
  String get comparisonNew;
  String get comparisonUnused;
  String showMoreComparisonRows(int n);
  String get noUsageInEitherPeriod;
  String get partlyUnpriced;
  String get comparisonUnpricedNote;
  String biggestIncrease(String project, String n);
  String biggestDrop(String project, String n);
  String compareWith(String previous);
  String get comparisonPreviousColumn;
  String get noComparisonPeriod;
  String get trendTokens;
  String get trendCost;
  String get trendUnpricedNote;
  String inventoryIntro(int total, int found);

  String get inventoryFound;

  String get inventoryIssues;

  String get inventoryHidden;

  String get inventoryMissing;

  String get inventorySearch;

  String get inventoryVisibility;

  String get inventoryFolder;

  String get inventoryFiles;

  String get inventoryLastUsed;

  String get inventoryShow;

  String get inventoryDenied;

  String get inventoryReadError;

  String inventoryMonth(String value);

  String inventoryFilesFound(int n);

  String get inventoryPathMissing;

  String get inventoryLocations;

  String get inventoryOpen;

  String get inventoryCopy;

  String get inventoryCopied;

  String get inventoryShowInStats;

  String get inventoryViewUsage;

  String progressSyncing(String tool);

  String get progressSynced;

  String progressDiscovering(String title);

  String progressReading(
    String title,
    String tool,
    int index,
    int total,
    int files,
  );

  String get progressFirst;

  String get progressReread;

  String get progressFirstHint;

  String progressFailed(String reason);

  String get progressEarlierDataPreserved;

  String progressIssues(int n);

  String get progressDismiss;

  String hiddenToolsNotice(int n);

  String get hiddenToolsManage;

  const AppStrings();

  String get languageCode;
  bool get isChinese => languageCode == 'zh';

  String get aDashMeansTheLogOmitsThe;
  String get aRealSamples;
  String get aRefreshIsAlreadyRunningWaitFor;
  String get aSessionIsATaskInAn;
  String get aSessionIsATaskInAn2;
  String get aSyncIsAlreadyRunningWaitingFor;
  String about0(Object? shortName);
  String about0TokenS(Object? value);
  String get aboutThisInstallationOfTokenLens;
  String activeDayCount(Object? active);
  String get activeDays;
  String get activeEveryDaySinceTrackingBegan;
  String get affectsData;
  String get afterSyncingYouLlSeeHowMany;
  String get appearanceAndInterface;
  String get numbersAndTime;
  String get networkAndUpdates;
  String get interfaceDensity;
  String get densityHint;
  String get comfortableDensity;
  String get compactDensity;
  String get interfaceScale;
  String get interfaceScaleHint;
  String get resetInterfaceScale;
  String get defaultPeriod;
  String get defaultPeriodHint;
  String get lastUsedPeriod;
  String get weekStartsOn;
  String get weekStartsOnHint;
  String get monday;
  String get sunday;
  String get newsPreferenceHint;
  String get localStatisticsOnly;
  String get localStatisticsOnlyHint;
  String get aiNews;
  String get aiNewsIsClosedReopenTheWindow;
  String get aiSummary;
  String get aiSummary2;
  String get aihotPicksComeFromThePublicRss;
  String get all;
  String get allCaughtUp;
  String get allSessionsShown;
  String get allTime2;
  String get allUnread;
  String get alreadyFilteredByThisFieldTryAnother;
  String alsoOn0(Object? value);
  String get anOlderCollectorLockWasFoundClose;
  String anomalyCrossFileConflict(String raw, String record);
  String anomalyCumulativeDecrease(String raw, String subject);
  String anomalyReadFailed(String raw, String subject);
  String anomalyRejected(String raw, String subject);
  String anomalySupersededReproduced(String raw, String record);
  String anomalyVanished(String raw, String subject);
  String get appearance;
  String get apply;
  String get asksApiGithubComForTheLatest;
  String get atListPrices;
  String atListPrices0RecordWithoutA(Object? value);
  String get autoRefresh;
  String average0PerSession(Object? value);
  String get averageSpeed;
  String get averageSpeedIncludesTheWait;
  String avg0(Object? tokens);
  String get avgPerRequest;
  String get averagePerRequestPrefix;
  String get bSyntheticSamples;
  String get baseTier;
  String get breakdown;
  String get breakdown2;
  String breakdownDescription(String period);
  String get builtInRate;
  String get busiestDay;
  String get busiestHour;
  String get byDay;
  String get byHour;
  String get byModel;
  String get byPopularity;
  String get byProject;
  String get byRequest;
  String get byTime;
  String get byTool;
  String get cache;
  String get cacheHit;
  String cacheHit0(Object? periodLabel);
  String get cacheRead;
  String get cacheReadsNewInputCacheReadsHigher;
  String get cacheSavings;
  String get cacheSavings2;
  String get cacheWrite;
  String get cacheWrite1h;
  String get cacheWrite5m;
  String get cacheWriteShort;
  String get cachedArticlesAreStillAvailableYouCan;
  String calendarDay(int month, int day);
  String calendarDayWeekdayWithYear(int year, int month, int day, int weekday);
  String calendarDayWithWeekday(int month, int day, int weekday);
  String calendarDayWithYear(int year, int month, int day);
  String calendarMonth(int year, int month);
  String get cancel;
  String get cancelRefresh;
  String get canceled;
  String get canceling;
  String get cancelingRefresh;
  String get cannotReadLogDirectory;
  String chartSpanningSessions(Object? tokens, Object? unit);
  String chartUnallocatedUsage(
    Object? tokens,
    Object? spanUnit,
    Object? bucketUnit,
  );
  String get checkAutomaticallyOnceADay;
  String get checkForUpdates;
  String checkedAt(Object? time);
  String get checkedAgainstPublicReferencesAndSamplesReport;
  String get checkedAgainstRealUsageLogs;
  String get checkedAgainstTheProviderSPricingPage;
  String get checkedWithSampleLogs;
  String get checking;
  String get checks;
  String get checksPassed;
  String get chinaStandardTimeUtc8;
  String get chinese;
  String get chineseLanguage;
  String get clear;
  String get clearFilters;
  String get clearSearch;
  String get close;
  String get closeNavigationMenu;
  String closePanel(String label);
  String get cny;
  String get community;
  String conditionalPriceTableLabel(Object? value);
  String get cost;
  String get costsAreEstimatesAtEachModelS3;
  String couldNotAccessLogDirectoriesFor0(Object? count);
  String get couldNotCancelWaitForTheCurrent;
  String syncStatusReadFailed(Object? failure);
  String get couldNotLoadRequestFailed;
  String exportFolderOpenFailed(Object? error);
  String get couldNotOpenTheArticleCheckYour;
  String get couldNotOpenTheContainingFolder;
  String get couldNotParse;
  String get couldNotParseThisSourceCachedArticles;
  String get couldNotReachTheSourceCheckYour;
  String get couldNotReadLocalStatusAfterRefresh;
  String get couldNotReadOrSaveLocalStatus;
  String get couldNotReadTheLocalCacheTry;
  String get couldNotSaveReadStatus;
  String get couldNotSaveSourceSettings;
  String get couldNotSaveStarredStatus;
  String exchangeRateUpdateFailed(Object? failure);
  String get counting;
  String get currency;
  String get currencyUsedToDisplayCosts;
  String get custom;
  String get dailyAverage;
  String get dailyUsageForThisSessionTodayIs;
  String get dark;
  String get dataDirectory;
  String get date;
  String get day;
  String dayCount(Object? streak);
  String daysAgo(Object? days);
  String get debugRunsRequireTokenLensPreviewData;
  String get deprecation;
  String get diagnosticsAbout;
  String get didNotUpdate;
  String get disable;
  String get disabled;
  String get dismissThisVersion;
  String get display;
  String get displayOnlyLedgerAmountsStayTheSame;
  String get displayPreferencesAndHowCostsAreCalculated;
  String get duration;
  String get eachRequestIncludesItsTimeModelAnd;
  String get eachSquareIsADayDarkerSquares;
  String emptyPeriodHint(Object? period);
  String get enable;
  String get enableOrDisableSourcesAndCheckRefresh;
  String get enabledSourcesHaveNoArticlesToShow;
  String get englishLanguage;
  String get enterAValidDateRange;
  String get estCost;
  String estCost0(Object? periodLabel);
  String estCost02(Object? value);
  String get estimatedCostPrefix;
  String get estimatedAtListPrices;
  String get estimatedFromLogTimestamps;
  String get estimatedFromReasoningStartEvents;
  String get estimatedFromWeeklyShare;
  String get estimatedPrice;
  String get evidence;
  String example0(Object? value);
  String exchangeRate(Object? rate, Object? updated);
  String get exportDiagnostics;
  String diagnosticsExportFailed(Object? error);
  String get export;
  String get exportCsv;
  String get exportJson;
  String get includeFullProjectPaths;
  String exportCompleted(String name);
  String get exporting;
  String newsFetchProgress(Object? completed, Object? total);
  String get filterBySourceAndType;
  String get firstToken;
  String get firstToken2;
  String get firstTokenWaitForTheReply;
  String get followSystem;
  String get found;
  String get foundTheLogDirectoryButCouldNot;
  String get fri2;
  String get from;
  String get fullSessionTotal;
  String get generalNoLabel;
  String get getANoticeWhenANewVersion;
  String get githubStars;
  String noonGreeting(int hour);
  String get goodAfternoon2;
  String get goodEvening;
  String get goodMorning;
  String get groupBy;
  String get hackerNewsPoints;
  String get handled;
  String get highestFirst;
  String holidayCountAndEnd(Object? days, Object? lastDate);
  String holidayPricingNote(Object? holidays, Object? range);
  String holidaysListedThrough0(Object? value);
  String get hour;
  String hourTick(Object? value);
  String hoursAndMinutesDuration(Object? value1, Object? value2);
  String daysAndHoursDuration(int days, int hours);
  String get howLargeNumbersAreShortened;
  String get howPricesWork;
  String get huggingFaceLikes;
  String get huggingFacePaperUpvotes;
  String get ifUsageLooksWrongSyncFailsOr;
  String includes0LocalRecordZeroCost(Object? count);
  String get includesAllUsage;
  String get includesAppAndSystemVersionsResultsAnd;
  String get incompletePromptLengthBaseTier;
  String inputOutputPrices(Object? input, Object? output);
  String get installAndUseASupportedToolThen;
  String get interfaceLanguage;
  String invalidUpdateCheckResponse(Object? checked, Object? retry);
  String get justNow;
  String get knownLimitations;
  String get last20Weeks;
  String get lastMonth;
  String lastSuccessfulRefresh0(Object? value);
  String get lastSyncDetails;
  String lastUsed0(Object? value);
  String get lastWeek;
  String get latest;
  String get ledgerPath;
  String get less;
  String get light;
  String get lightDarkOrSystemTheme;
  String get likes;
  String listPriceWithUnpricedRecords(Object? count);
  String get listSeparator;
  String get loadMore;
  String get loading;
  String get loadingSession;
  String get loadingUsageForThisPeriod;
  String get local;
  String get localProviderZeroCost;
  String logFileCount(Object? value);
  String get logRetention;
  String logsGone(Object? value);
  String longContextPrompt0Tokens(Object? count);
  String longContextSummary(Object? threshold, Object? count);
  String get longContextTiers;
  String get longestStreak;
  String longestStreakDays(Object? streak);
  String get lowestFirst;
  String get manageSources;
  String get markAllAsRead;
  String get markAsRead;
  String get markAsUnread;
  String get markThisDayAsRead;
  String minutesDuration(Object? minutes);
  String missingFromLogs0(Object? missing);
  String get model;
  String modelCount(Object? models);
  String get modelNotLogged;
  String get modelsAppearHereAfterSyncingToolLogs;
  String get modelsUsed;
  String get mon2;
  String get month;
  String get month2;
  String get more;
  String moreActionsFor0(Object? name);
  String get mostTokensAreReusedContextWhichCosts;
  String get mostUsed;
  String get mostlyPerRequest;
  String get needsReview;
  String get neverChecked;
  String get neverCheckedAutomaticChecksOff;
  String get neverRefreshed;
  String get newArticlesWillAppearAfterTheNext;
  String get newInput;
  String get newInputIsContentSentToThe;
  String newVersion(Object? version);
  String get news;
  String newsItemsSummary(Object? count, Object? unreadSuffix);
  String newsRefreshSummary(Object? count, Object? lastRefresh);
  String get noArticlesYet;
  String get noDailyRecords;
  String get noHolidaysListed;
  String get noIndividualRequestsInThisPeriod;
  String get noIndividualRequestsInThisPeriodTools;
  String get noListPrice;
  String get noLogsFoundForSupportedToolsOn;
  String get noMatchingArticles;
  String get noModelsUsedYet;
  String get noPopularityDataForTheseResults;
  String get noPricingYet;
  String get noProjectLogged;
  String noReleaseCheckResult(Object? time);
  String get noRequestsInThisPeriodHaveTiming;
  String get noSessionsYet;
  String get noStarredArticles;
  String get noSuccessfulRefreshYet;
  String get noSyncHistory;
  String get noSyncYet;
  String get noToolLogsFoundYet;
  String get noUsage;
  String get noUsage2;
  String noUsageForPeriod(Object? label);
  String get noUsageMatchesTheseFiltersInThis;
  String noUsageRecordedFor0ToCompare(Object? comparison);
  String get noUsageYet;
  String get notLogged;
  String get nothingIsCachedYetTheAppRefreshes;
  String get numberUnits;
  String get offPeak;
  String get offPeakPricingAppliesAtOtherTimes;
  String offPeakSummary(Object? count);
  String get official;
  String get officialPrice;
  String get officialPricingPage;
  String get offline;
  String get onDaysWithUsage;
  String get onePerRequest;
  String get oneRowPerRequestSelectARow;
  String get onlyASessionTotalIsLoggedCounted;
  String openArticleInDefaultBrowser0(Object? title);
  String get openContainingFolder;
  String get openDownloadPage;
  String get openNavigationMenu;
  String get openingTheLocalNewsCache;
  String outOfDays(Object? elapsed);
  String get output;
  String get outputTokensDividedByTotalRequestTime;
  String get over100MillionTokensInOneRequest;
  String get overview;
  String get overview2;
  String get overviewComparisonEqualLink;
  String overviewComparisonLead(
    String period,
    String comparison,
    String relation,
  );
  String get overviewComparisonOtherLink;
  String overviewComparisonTail(String relation, String comparison);
  String get overviewHigher;
  String get overviewLower;
  String get overviewMajorityLead;
  String get overviewMajorityTail;
  String get overviewMuchHigher;
  String get overviewMuchLower;
  String get overviewSecondToolLead;
  String get overviewSentenceEnd;
  String get overviewSimilar;
  String get overviewTopToolLead;
  String overviewTrackingSince(String date);
  String get pageNavigation;
  String get pastYear;
  String get peak;
  String get peakAndOffPeak;
  String peakHourShare(Object? tokens, Object? share);
  String get perMillionTokens;
  String get perRequest;
  String get perRequest2;
  String get perRequestEstimatesBasedOnLogTimestamps;
  String get perTurn;
  String get period;
  String get periodAllTime;
  String periodUsage(Object? value);
  String get popular;
  String get priceUnavailable;
  String get priceUnverified;
  String get pricing;
  String get pricingIsUnavailableForThisModel;
  String get pricingIsUnpublishedOrUnverifiedEstimatedFrom;
  String get pricingSettings;
  String get pricingVersion;
  String get project;
  String prompt0Tokens(Object? count);
  String get promptLengthIncludesNewInputCacheReads;
  String get pts;
  String publishedAt0(Object? value);
  String publishedOn0(Object? value);
  String get rankedByThisSource;
  String get rateLimited;
  String rateLimitedUpdateCheck(Object? time);
  String rateUpdatedAt(int month, int day, String hour, String minute);
  String get readAndStarredStatusUnavailable;
  String get reading;
  String get readingLogs;
  String get readsLogsOnThisComputerAndLeaves;
  String get recentSessions;
  String recordCount(Object? count);
  String get recordType;
  String get records;
  String get recordsComplete;
  String recordsNoun(int count);
  String recordsProcessed(
    Object? attempted,
    Object? inserted,
    Object? updated,
    Object? unchanged,
    Object? rejected,
  );
  String get recordsWithoutPricesAreExcludedFromCost;
  String get refreshAll;
  String get refreshCanceled;
  String get refreshFailedShowingCachedNews;
  String get refreshFailedTryAgainShortly;
  String get refreshNow;
  String refreshProgress(Object? completed, Object? total);
  String get refreshThisSource;
  String refreshed0(Object? value);
  String get refreshesEvery30MinutesWhileOpenRate;
  String get refreshing;
  String get refreshing2;
  String get release;
  String releaseDatePrefix(Object? value);
  String remainingTools(Object? value1, Object? value2);
  String remove0Filter(Object? label);
  String requestCount(Object? value);
  String requestCountSuffix(int count);
  String get requestFailed;
  String requestFailed0(Object? failure);
  String get requests;
  String requests0(Object? periodLabel);
  String get rereadAllLogs;
  String get rereadAllLogsWithoutUsingThePrevious;
  String get rereading;
  String get responseTooLarge;
  String get retry;
  String get retryLoading;
  String retryingAt0(Object? value);
  String reviewableRecords(Object? value);
  String get sat2;
  String savedTo0(Object? exportPath);
  String get scanAgain;
  String get schemaVersion;
  String get scrollableTableOfConditionalPrices;
  String get searchTitlesAndSummaries;
  String secondsDuration(Object? value);
  String get seeHowManyTokensYourAiCoding;
  String selectABarForThat0S(Object? unit);
  String selectABarToFilterToThat(Object? unit);
  String get selectARowForCachePricesAnd;
  String get selectARowToAddItTo;
  String get selectTheStarNextToAnArticle;
  String selectToViewThis0SBreakdown(Object? value);
  String get selectedPeriod;
  String get selectedPeriodInSentence;
  String get sentenceSeparator;
  String get session;
  String get sessionDetails;
  String sessionForTool(String tool);
  String sessionHeading(
    Object? tool,
    Object? date,
    Object? time,
    Object? duration,
  );
  String get sessionId;
  String sessionRecordSummary(Object? count, Object? description);
  String get sessionSnapshotBaseTier;
  String sessionSpan(Object? duration, Object? days);
  String get sessionTotalsOnly;
  String get sessionTotalsOnly2;
  String get sessionUnavailable;
  String get sessionUsageIsAvailableRequestTimesAre;
  String get sessions;
  String sessions0(Object? value);
  String get sessionsNavigation;
  String get sessionsAppearHereAfterSyncingToolLogs;
  String get sessionsMixingBothRecordTypes;
  String sessionsNoun(int count);
  String sessionsWithUsageIn0SortedBy(Object? periodLabel);
  String get settings;
  String get share;
  String get shareOfInputServedFromCache;
  String shortMonth(int month);
  String shortWeekday(int weekday);
  String show0More(Object? value);
  String show30More0Left(Object? value);
  String showing0Session(Object? count);
  String skipped0FileFromToolsWithNo(Object? skippedFiles);
  String get slowerThan90OfRequestsHere;
  String get someSessionsHaveOnlyATotalAnd;
  String get sort;
  String sortBy0(Object? value);
  String sortedBy0HighestFirstItemsWithout(Object? unit);
  String get sortedByUsageInThisPeriod;
  String get source;
  String source0(Object? sourceName);
  String sourceCheckLabel(String check, String count);
  String sourceCheckRecordCount(int count);
  String sourceCheckSessionCount(int count);
  String get sourceId;
  String sourceRecordCount(Object? value);
  String sourcesIntro(Object? found);
  String sourcesNotUpdated(Object? failed);
  String get speed;
  String get speed2;
  String get speedTokenS;
  String get speedTokensPerSecondWhileReplying;
  String get star;
  String get starred;
  String starred0(Object? starred);
  String get stars;
  String get start;
  String get startCounting;
  String sessionStartLabel(Object? value);
  String startedOn(String date);
  String get status;
  String get stillUpLate;
  String get subscription;
  String get subscriptionsAreBilledSeparately;
  String get sun2;
  String get supported;
  String supportedToolCount(Object? supported);
  String supportedToolsMissing(Object? missingCount);
  String get syncComplete;
  String syncCompleted(
    Object? files,
    Object? reused,
    Object? inserted,
    Object? updated,
    Object? seconds,
  );
  String syncFailed0(Object? error);
  String get syncFailedPreviouslyCollectedDataIsStill;
  String syncFinishedWithWarnings(Object? warning);
  String get syncNow;
  String get syncUsage;
  String syncedHoursAgo(Object? hours);
  String syncedMinutesAgo(Object? minutes);
  String synced0NoIssues(Object? value);
  String syncedDaysAgo(Object? days);
  String get syncedJustNow;
  String get syncing;
  String get syncing2;
  String get syncing3;
  String tableSpanningSessions(
    Object? tokens,
    Object? spanUnit,
    Object? bucketUnit,
  );
  String get technicalDetails;
  String get technicalNotes;
  String thisHourSoFar(Object? hour, Object? comparison);
  String builtInVersion(Object? value);
  String toolDidNotLogGenerationTime(Object? tool);
  String toolDidNotLogFirstTokenTime(Object? tool);
  String lastSyncReadFailures(Object? failures);
  String filteredPeriod(Object? value);
  String fractionalHours(Object? value);
  String hoursAgo(Object? hours);
  String updateAvailable(Object? latest);
  String onlyVersionSoFar(Object? current);
  String upToDate(Object? current);
  String sourceStatusWithLastRefresh(Object? status, Object? lastSuccess);
  String averageSpeedIncludesWait(Object? tool);
  String roundedMinutes(Object? value);
  String minutesAgo(Object? minutes);
  String additionalNewsSources(Object? count);
  String cacheInputShare(Object? value);
  String shareOfTotal(Object? value);
  String sessionTotalsOnlyForTool(Object? name);
  String peakHoursInTimeZone(Object? value);
  String sourceMonthlyTokens(Object? tokens);
  String partiallyUnreadSuffix(Object? unread);
  String get chineseNumberUnits;
  String get chineseNumberExample;
  String get englishNumberExample;
  String get theAppWillTryAgainTomorrowYou;
  String get theClientDidNotReportThisField;
  String get theEarliestRecord;
  String theFirstRecordIsFrom0Older(Object? firstSeenText);
  String get theLastSyncDidNotFinish;
  String get lastSyncIncomplete;
  String get recentSyncIncomplete;
  String get theLocalCacheIsUnavailableTryRefreshing;
  String get theLogDidNotRecordThisField;
  String get theLogHasNoSessionIdFor;
  String get theResponseExceededTheSizeLimitCached;
  String get theSameTimeYesterday;
  String get theSourceDidNotProvideAPublication;
  String get theSourceIsRateLimitingRequestsIt;
  String get theSourceIsUnavailableTryAgainShortly;
  String get theSourceReturnedAnUnsupportedFormatCached;
  String get theSourceTimedOutTryAgainShortly;
  String get theToolDidNotLogThis;
  String get theWaitTimedOutSyncMayStill;
  String themeShortcut(Object? value);
  String get thereAreNoPricesForTheModels;
  String theseResultsUse0PopularityScoresUse(Object? units);
  String get thisCodexRequestBeganWithATool;
  String get thisHour;
  String get thisMonth;
  String get thisMonth2;
  String get thisRequestDidNotFinishNormallySo;
  String get thisSessionMayNoLongerBeIn;
  String get thisToolLogsOneTotalPerSession;
  String get thisToolLogsTimingForAWhole;
  String get thisToolLogsTimingForAWhole2;
  String get thisWeek;
  String get thisWeek2;
  String get thisYearSTotal;
  String get thu2;
  String get tier;
  String get time;
  String get timeFromSendingTheRequestToThe;
  String get timeOutsideExpectedRange;
  String get timeUnavailable;
  String get timedOnly;
  String get timedOut;
  String timedRequestCoverage(Object? requests, Object? recorded);
  String moreTimingEstimates(int count);
  String get timingReportedByTheClient;
  String get to;
  String get today;
  String today0(Object? base);
  String get tokenBreakdown;
  String get tokenLensOnlyReadsLogFilesCheck;
  String get tokenLensReadsAiCodingToolLogs;
  String get tokenLensSyncsOnceEachTimeIt;
  String get tokensCountTowardUsageTheirCostIs;
  String get tokensGeneratedPerSecondAfterOutputBegins;
  String get tokenUnit;
  String get tool;
  String get toolSources;
  String get toolUpdates;
  String get tools;
  String toolsFound(Object? count);
  String toolsFoundOnComputer(Object? count);
  String get toolsInThisPeriod;
  String get toolsThatLogOnlySessionTotalsHave;
  String topFiveModels(Object? value);
  String get topModels;
  String get total;
  String total0(Object? value);
  String total01(Object? value1, Object? value2);
  String get totalEstCost;
  String get totalRequests;
  String get totalSoFar;
  String get totalUsage;
  String get trend;
  String trendAxisLabels(Object? labels);
  String get trendChartFocusItAndUseThe;
  String get trendChartFocusItAndUseThe2;
  String trendWithAverageHint(Object? unit, Object? actionHint);
  String trendingItemLabel(
    Object? rank,
    Object? title,
    Object? score,
    Object? unit,
  );
  String get trendingNow;
  String get trendingSources;
  String get tryAnotherCategorySourceTypeOrSearch;
  String get tryAnotherFilter;
  String get tue2;
  String get type;
  String typicalAndSlowTiming(Object? typical, Object? slow);
  String unchangedFiles(Object? reused);
  String get unknownModel;
  String get unknownTime;
  String get unknownTimingSource;
  String get unmarked;
  String get unpriced;
  String get unpricedBecauseTheModelIsMissing;
  String unreachableUpdateCheck(Object? checked, Object? retry);
  String get unread;
  String unread0(Object? unread);
  String unreadCount(Object? count);
  String get unstar;
  String get unsupportedFormat;
  String get upcoming;
  String get upcoming2;
  String updateAvailableDetails(Object? released, Object? version);
  String get updateCheckFailed;
  String get updateRate;
  String get updates;
  String get updating;
  String get upvotes;
  String get usage;
  String get usageAppearsHereAfterTheToolWrites;
  String get usageBreakdown;
  String get usageByTool;
  String get usageIsCountedWhenEachRecordOccurred;
  String get usageIsReady;
  String get usageOverview;
  String get usageReflectsTheFiltersSessionTotalsCover;
  String usageTrendHint(Object? unit, Object? actionHint);
  String get usd;
  String get usdMillionTokensADashMeansNo;
  String get useASupportedAiCodingToolThen;
  String get verifiedAgainstTheProviderSPricingPage;
  String get verifiedWithRealLogs;
  String get version;
  String get view;
  String view0InBreakdown(Object? value);
  String get view2;
  String get viewAll;
  String get viewAllSessions;
  String get viewBreakdown;
  String get viewDetails;
  String viewSession01(Object? session, Object? tool);
  String get viewThisMonth;
  String get viewToolSources;
  String get viewUpdateDetails;
  String get viewUsage;
  String get sourceViewUsage;
  String vs0(Object? comparison);
  String get vsThisTimeYesterday;
  String get wed2;
  String get weightedByTime;
  String get welcomeToTokenLens;
  String get whenRepeatedContextHitsTheCacheIt;
  String get whereTheTokensWent;
  String get withUsageInThisPeriod;
  String get workingDirectory;
  String yearActiveDaysAndStreakTail(int activeDays, int streak);
  String yearActiveDaysTail(int activeDays);
  String get yearActivityLead;
  String yearNewcomerLead(String date);
  String get yesterday;
  String yesterday0(Object? base);
  String get youCanRetryNow;
  String currentVersion(Object? current);
}
