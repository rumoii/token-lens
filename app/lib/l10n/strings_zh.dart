part of 'app_strings.dart';

final class ChineseStrings extends AppStrings {
  @override
  String get miniWindow => '迷你窗口';

  @override
  String get miniHintTitle => '想边用 AI 边看 token 用量？';

  @override
  String get miniHintDescription => '迷你窗口可以置顶在屏幕一角，随时看今天的用量和正在用的模型。';

  @override
  String get miniHintOpen => '打开迷你窗口';

  @override
  String get miniHintDismiss => '不再提示';

  @override
  String get onboardingShortcut => '在桌面创建快捷方式';

  @override
  String get onboardingShortcutHint => '在桌面放一个 Token Lens 图标，以后双击就能打开。';

  @override
  String get onboardingShortcutCreated => '已在桌面创建快捷方式';

  @override
  String get onboardingShortcutFailed => '没能创建桌面快捷方式，可以稍后在「价格与设置」里再试。';

  @override
  String get desktopShortcut => '桌面快捷方式';

  @override
  String get desktopShortcutHint => '在桌面放一个 Token Lens 图标。挪动过程序文件夹，就点这里重新创建。';

  @override
  String get desktopShortcutCreate => '创建快捷方式';

  @override
  String get desktopShortcutRecreate => '重新创建';

  @override
  String get desktopShortcutCreated => '已创建';

  @override
  String get desktopShortcutFailed => '没能创建桌面快捷方式。';

  @override
  String get miniPin => '置顶';

  @override
  String get miniUnpin => '取消置顶';

  @override
  String get miniSettings => '迷你窗口设置';

  @override
  String get miniExpand => '展开完整窗口';

  @override
  String miniEstimate(String amount) => '约 $amount';

  @override
  String miniInterval(int seconds) =>
      seconds < 60 ? '$seconds 秒' : '${seconds ~/ 60} 分钟';

  @override
  String miniUpdated(int age, int interval) => age < 2
      ? '刚刚更新 · 每 ${miniInterval(interval)}刷新'
      : '${miniInterval(age)}前更新 · 每 ${miniInterval(interval)}刷新';

  @override
  String get miniSyncFailed => '同步失败，已保留先前的数据';

  @override
  String get miniProjects => '项目';

  @override
  String miniTopProjects(int count) => '前 $count 个项目';

  @override
  String get miniAllProjects => '全部项目';

  @override
  String miniLatest(int count) => '最近 $count 条';

  @override
  String miniMoreProjects(int count) => '其他 $count 个项目';

  @override
  String get miniActiveModels => '在用的模型 · 最近 5 分钟';

  @override
  String miniMoreModels(int count) => '另有 $count 个模型';

  @override
  String miniApproxSpeed(String value) => '≈ $value token/s';

  @override
  String miniUntimedModel(String tool) => '$tool 没在日志里记生成时间，这里显示最近 5 分钟的用量。';

  @override
  String miniOutput(String value) => '输出 $value';

  @override
  String miniFirstToken(String seconds) => '首字 $seconds 秒';

  @override
  String miniHour(int hour) => '$hour 点';

  @override
  String get miniNoUsage => '今天还没有用量';

  @override
  String get miniNoRequests => '今天还没有请求';

  @override
  String get miniNoModels => '最近 5 分钟没有在用的模型';

  @override
  String get miniChartRange => '用量图范围';

  @override
  String miniChartChoice(int minutes) => minutes == 60 ? '1 小时' : '$minutes 分钟';

  @override
  String get miniChartNow => '现在';

  @override
  String miniChartTip(String time, String usage, bool current) =>
      "$time${current ? ' 至今' : ''} · $usage token";

  @override
  String miniChartLabel(int minutes) => '最近 $minutes 分钟用量，每分钟一个点';

  @override
  String get miniRefreshEvery => '刷新间隔';

  @override
  String get miniProjectsShown => '项目显示';

  @override
  String miniProjectsChoice(int count) => switch (count) {
    -1 => '自动铺满',
    0 => '全部',
    _ => '前 $count 个',
  };

  @override
  String get miniSwitchFailed => '切换窗口模式失败。';

  @override
  StartupFailureCopy startupFailureCopy(
    StartupFailure failure,
  ) => switch (failure.code) {
    StartupErrorCode.alreadyRunning => (
      title: 'Token Lens 已经在运行',
      body: '这个数据目录正被另一个 Token Lens 窗口使用。请回到已打开的窗口。',
      steps: const [
        '在任务栏或系统托盘里找 Token Lens 的窗口。',
        '找不到的话，在任务管理器里结束 token-lens.exe，再重新打开。',
      ],
    ),
    StartupErrorCode.appFilesMissing => (
      title: '程序文件不完整',
      body: 'Token Lens 的核心组件没能加载，通常是只拷了 token-lens.exe，或者解压不完整。',
      steps: const ['重新解压整个压缩包。', 'token-lens.exe 要和同一文件夹里的 dll、data 文件夹放在一起。'],
    ),
    StartupErrorCode.dataDirDenied => (
      title: '没有权限读写数据目录',
      body: 'Token Lens 需要在下面这个文件夹里读写账本和设置，但系统拒绝了访问。',
      steps: const [
        '检查这个文件夹是否被设为只读，或被安全软件拦截。',
        '数据目录在同步盘里（如 OneDrive）时，等同步完成后再打开。',
      ],
    ),
    StartupErrorCode.diskFull => (
      title: '磁盘空间不足',
      body: '数据目录所在的磁盘没有剩余空间，Token Lens 无法写入账本。腾出一些空间后重新打开。',
      steps: const [],
    ),
    StartupErrorCode.ledgerCorrupt => (
      title: '统计账本已损坏',
      body: '账本文件 ledger.db 无法读取。请不要删除它：导出诊断日志发给维护者，再决定怎么恢复。',
      steps: const [],
    ),
    StartupErrorCode.ledgerTooNew => (
      title: '账本来自更新版的 Token Lens',
      body:
          '这个账本的结构版本是 ${failure.ledgerVersion ?? '—'}，这个版本的 Token Lens 只支持到 ${failure.supportedVersion ?? '—'}。为了不损坏数据，它不会写入这个账本。请改用更新版的 Token Lens。',
      steps: const [],
    ),
    StartupErrorCode.startupFailed => (
      title: '无法启动 Token Lens',
      body: '启动时遇到了没有预料到的错误。导出诊断日志发给维护者，可以帮助找到原因。',
      steps: const [],
    ),
  };

  @override
  String get startupOpenLogFolder => '打开日志文件夹';

  @override
  String get startupOpenAppFolder => '打开程序所在文件夹';

  @override
  String get startupDiagnosticsPrivacy =>
      '诊断日志包含应用和系统版本、出错原因和最近 7 天的运行日志，不包含账本和任何对话内容；用户目录显示成 ~。';

  @override
  String get startupPrivacyWithoutCore => '程序核心没能加载，这一页导不出诊断日志。';

  @override
  String get startupDetails => '详细信息';

  @override
  String get startupErrorCode => '错误代码';

  @override
  String get startupDataFolder => '数据目录';

  @override
  String get startupMessage => '原始信息';

  @override
  String get startupStatisticsUnavailable => '统计不可用';

  @override
  String get startupOverview => '总览';

  @override
  String get startupDetail => '明细';

  @override
  String get startupSessions => '会话';

  @override
  String get startupNewsStillWorks => 'AI 热点仍可使用。';

  @override
  String get startupExportFailureHelp => '可以点「打开日志文件夹」，把里面最近的日志直接发给维护者。';

  @override
  String get startupExportDestinationUnavailable => '下载文件夹和数据目录都不可用。';

  @override
  String get spansPeriod => '跨时段';

  @override
  String get copySessionId => '复制会话 ID';

  @override
  String get sessionIdCopied => '已复制会话 ID';

  @override
  String heatTokenRange(String from, String to) => '$from–$to token';

  @override
  String heatTokensAndAbove(String from) => '$from token 以上';

  @override
  String discoveredLogTools(int count) => '这台电脑上找到 $count 个工具的日志';

  @override
  String discoveredLogFiles(int count) => '$count 个文件';

  @override
  String moreDiscoveredTools(int count) => '还有 $count 个';

  @override
  String get noSupportedToolsDiscovered => '这台电脑上还没找到支持的 AI 编程工具';

  @override
  String get completionByTool => '按工具拆开';

  @override
  String completionToolCount(int count) => '$count 个工具';

  @override
  String otherCompletionTools(int count) => '其他 $count 个工具';

  @override
  String completionTokenEstimate(String cost) => 'token · 约值 $cost';

  @override
  String get morePeriods => '更多';

  @override
  String get lastSevenDays => '最近 7 天';

  @override
  String get lastThirtyDays => '最近 30 天';

  @override
  String get lastSevenDaysInSentence => '最近 7 天';

  @override
  String get lastThirtyDaysInSentence => '最近 30 天';

  @override
  String get dayBeforeYesterday => '前天';

  @override
  String get weekBeforeLast => '上上周';

  @override
  String get monthBeforeLast => '上上个月';

  @override
  String get previousSevenDays => '之前 7 天';

  @override
  String get previousThirtyDays => '之前 30 天';

  @override
  String comparisonDates(String current, int n, String previous, int m) =>
      comparisonDateRanges('$current（$n 天）', '$previous（$m 天）');

  @override
  String comparisonDateRanges(String current, String previous) =>
      '$current 对比 $previous';

  @override
  String get sessionSearch => '搜项目、会话 ID、工具或模型';

  @override
  String noMatchingSessions(String q) => '没有找到和“$q”匹配的会话';

  @override
  String get clearSessionSearch => '清除';

  @override
  String get sessionSortCost => '约值';

  @override
  String get sessionSortStarted => '开始时间';

  @override
  String get sessionSortRecent => '最近活动';

  @override
  String get sessionSortRequests => '时段内请求数';

  @override
  String get sortDescending => '降序';

  @override
  String get sortAscending => '升序';

  @override
  String sortedSessions(String period, String sort) =>
      '$period有用量的会话，按$sort排序。累计是整个会话的总数。';

  @override
  String sessionSortUsageInSentence(String periodLabel) =>
      periodUsage(periodLabel);

  @override
  String get sessionSortCostInSentence => '约值';

  @override
  String get sessionSortStartedInSentence => '开始时间';

  @override
  String get sessionSortRecentInSentence => '最近活动';

  @override
  String get sessionSortRequestsInSentence => '时段内请求数';

  @override
  String get filterSearch => '搜索';

  @override
  String get noMatchingOptions => '没有匹配的选项';

  @override
  String get seeWhatChanged => '看变化 →';

  @override
  String get whatChangedFromPrevious => '比上期变化在哪';

  @override
  String get comparisonCurrent => '本期';

  @override
  String get comparisonPrevious => '上期';

  @override
  String get comparisonChange => '差额';

  @override
  String get sortedBySizeOfChange => '按增减多少排序';

  @override
  String get comparisonNew => '本期新增';

  @override
  String get comparisonUnused => '本期未用';

  @override
  String showMoreComparisonRows(int n) => '展开其余 $n 项';

  @override
  String get noUsageInEitherPeriod => '两期都没有用量';

  @override
  String get partlyUnpriced => '含未定价';

  @override
  String get comparisonUnpricedNote => '有未定价的记录，金额只算已定价的部分。';

  @override
  String biggestIncrease(String project, String n) =>
      '增加最多的是 $project（+$n token）。';

  @override
  String biggestDrop(String project, String n) => '减少最多的是 $project（−$n token）。';

  @override
  String compareWith(String previous) => '对比$previous';

  @override
  String get comparisonPreviousColumn => '上期';

  @override
  String get noComparisonPeriod => '全部和自选日期没有可对比的上期';

  @override
  String get trendTokens => 'token';

  @override
  String get trendCost => '金额';

  @override
  String get trendUnpricedNote => '未定价的用量不计入金额。';

  @override
  String inventoryIntro(int total, int found) =>
      '支持 $total 个 AI 编程工具，这台电脑上找到 $found 个。Token Lens 只读它们的日志，不上传，也不改动这些工具。';

  @override
  String get inventoryFound => '已找到';

  @override
  String get inventoryIssues => '有问题';

  @override
  String get inventoryHidden => '已隐藏';

  @override
  String get inventoryMissing => '没装';

  @override
  String get inventorySearch => '搜工具或路径';

  @override
  String get inventoryVisibility =>
      '隐藏只影响显示：隐藏的工具不出现在总览、明细、会话和侧栏里，日志照常读取、记账，随时可以恢复。';

  @override
  String get inventoryFolder => '日志目录';

  @override
  String get inventoryFiles => '文件';

  @override
  String get inventoryLastUsed => '最近使用';

  @override
  String get inventoryShow => '显示';

  @override
  String get inventoryDenied => '没有权限';

  @override
  String get inventoryReadError => '读取出错';

  @override
  String inventoryMonth(String value) => '本月 $value';

  @override
  String inventoryFilesFound(int n) => '找到 $n 个文件';

  @override
  String get inventoryPathMissing => '不存在';

  @override
  String get inventoryLocations => '会在这些位置找日志';

  @override
  String get inventoryOpen => '打开';

  @override
  String get inventoryCopy => '复制路径';

  @override
  String get inventoryCopied => '已复制';

  @override
  String get inventoryShowInStats => '在统计中显示';

  @override
  String get inventoryViewUsage => '查看用量';

  @override
  String progressSyncing(String tool) => '同步中 · $tool';

  @override
  String get progressSynced => '已同步';

  @override
  String progressDiscovering(String title) => '$title：正在查找日志目录';

  @override
  String progressReading(
    String title,
    String tool,
    int index,
    int total,
    int files,
  ) =>
      '$title：正在读取 $tool（第 $index/$total 个工具）· 已读 $files 个文件。读完的工具会先显示出来，可以照常查看。';

  @override
  String get progressFirst => '第一次同步';

  @override
  String get progressReread => '重新读取全部日志';

  @override
  String get progressFirstHint => '第一次同步还没读完，下面是已经读到的部分。';

  @override
  String progressFailed(String reason) => '同步失败：$reason';

  @override
  String get progressEarlierDataPreserved => '已保留先前采集的数据。';

  @override
  String progressIssues(int n) => '同步完成，但有 $n 处异常';

  @override
  String get progressDismiss => '关闭';

  @override
  String hiddenToolsNotice(int n) => '已隐藏 $n 个工具';

  @override
  String get hiddenToolsManage => '管理';

  const ChineseStrings();

  @override
  String get languageCode => 'zh';

  @override
  String get aDashMeansTheLogOmitsThe =>
      '“—”表示日志里没记，鼠标停上去看原因。褐色是这里最慢的一成。带“≈”的是算上等待的平均速度。';

  @override
  String get aRealSamples => 'A（真实样本）';

  @override
  String get aRefreshIsAlreadyRunningWaitFor => '已有刷新正在进行，请等待完成。';

  @override
  String get aSessionIsATaskInAn => '每次打开工具做的一件事';

  @override
  String get aSessionIsATaskInAn2 =>
      '每次打开 AI 工具做的一件事，最近的在最上面。点一个看它用了哪些模型、花在什么时候。';

  @override
  String get aSyncIsAlreadyRunningWaitingFor => '已有同步在执行，正在等待完成';

  @override
  String about0(Object? shortName) => '$shortName说明';

  @override
  String about0TokenS(Object? value) => '约 $value token/s';

  @override
  String get aboutThisInstallationOfTokenLens => '关于这台电脑上的 Token Lens';

  @override
  String activeDayCount(Object? active) => '一共活跃 $active 天';

  @override
  String get activeDays => '活跃天数';

  @override
  String get activeEveryDaySinceTrackingBegan => '从第一天起没断过';

  @override
  String get affectsData => '有影响';

  @override
  String get afterSyncingYouLlSeeHowMany => '同步之后，这里会显示每个 AI 编程工具用了多少 token。';

  @override
  String get appearanceAndInterface => '外观与界面';

  @override
  String get numbersAndTime => '数字与时间';

  @override
  String get networkAndUpdates => '联网与更新';

  @override
  String get interfaceDensity => '界面密度';

  @override
  String get densityHint => '紧凑模式收紧卡片和表格的留白，一屏看更多行';

  @override
  String get comfortableDensity => '舒适';

  @override
  String get compactDensity => '紧凑';

  @override
  String get interfaceScale => '界面缩放';

  @override
  String get interfaceScaleHint => '在系统显示缩放的基础上再放大或缩小';

  @override
  String get resetInterfaceScale => '恢复 100%';

  @override
  String get defaultPeriod => '默认时段';

  @override
  String get defaultPeriodHint => '打开应用时总览和明细停在哪个时段';

  @override
  String get lastUsedPeriod => '上次用的';

  @override
  String get weekStartsOn => '每周从哪天开始';

  @override
  String get weekStartsOnHint => '影响“本周”的范围、热力图和周对比';

  @override
  String get monday => '周一';

  @override
  String get sunday => '周日';

  @override
  String get newsPreferenceHint => '在侧栏显示，程序开着时每 30 分钟刷新一次。关掉后不再联网获取新闻。';

  @override
  String get localStatisticsOnly => '只用本地统计，不刷 AI 热点';

  @override
  String get localStatisticsOnlyHint => '不显示「AI 热点」，也不联网获取新闻。之后可以在「价格与设置」里打开。';

  @override
  String get aiNews => 'AI 热点';

  @override
  String get aiNewsIsClosedReopenTheWindow => 'AI 热点已关闭，请重新打开窗口。';

  @override
  String get aiSummary => 'AI 摘要  ';

  @override
  String get aiSummary2 => 'AI 摘要';

  @override
  String get aihotPicksComeFromThePublicRss =>
      'AIHOT 精选来自 aihot.news 的公开 RSS，标题和摘要由它的模型生成；原文链接指向原始出处。';

  @override
  String get all => '全部';

  @override
  String get allCaughtUp => '都读完了';

  @override
  String get allSessionsShown => '已经是全部了';

  @override
  String get allTime2 => '累计';

  @override
  String get allUnread => '，全部未读';

  @override
  String get alreadyFilteredByThisFieldTryAnother => '已经按这一项筛选了，换个拆法看看';

  @override
  String alsoOn0(Object? value) => '也见于 $value';

  @override
  String get anOlderCollectorLockWasFoundClose => '检测到旧版采集锁，请退出旧版后处理遗留锁文件。';

  @override
  String anomalyCrossFileConflict(String raw, String record) => raw;

  @override
  String anomalyCumulativeDecrease(String raw, String subject) => raw;

  @override
  String anomalyReadFailed(String raw, String subject) => raw;

  @override
  String anomalyRejected(String raw, String subject) => raw;

  @override
  String anomalySupersededReproduced(String raw, String record) => raw;

  @override
  String anomalyVanished(String raw, String subject) => raw;

  @override
  String get appearance => '外观';

  @override
  String get apply => '应用';

  @override
  String get asksApiGithubComForTheLatest =>
      '只向 api.github.com 询问本项目最新的正式版本，不带账号、凭据或用量数据。关掉后只在点“检查更新”时联网。';

  @override
  String get atListPrices => '按公开价估算';

  @override
  String atListPrices0RecordWithoutA(Object? value) =>
      '按公开标准价估算，另有 $value 条记录没有价格';

  @override
  String get autoRefresh => '自动刷新';

  @override
  String average0PerSession(Object? value) => '平均每个 $value';

  @override
  String get averageSpeed => '平均速度';

  @override
  String get averageSpeedIncludesTheWait => '平均速度（算上等待）';

  @override
  String avg0(Object? tokens) => '平均 $tokens';

  @override
  String get avgPerRequest => '平均每次';

  @override
  String get averagePerRequestPrefix => '平均每次 ';

  @override
  String get bSyntheticSamples => 'B（合成样本）';

  @override
  String get baseTier => '基础档';

  @override
  String get breakdown => '明细';

  @override
  String get breakdown2 => '拆开看';

  @override
  String breakdownDescription(String period) => '$period的用量，按工具、模型、项目和时间拆开看。';

  @override
  String get builtInRate => '内置汇率';

  @override
  String get busiestDay => '最忙的一天';

  @override
  String get busiestHour => '最忙的一小时';

  @override
  String get byDay => '按天';

  @override
  String get byHour => '按小时';

  @override
  String get byModel => '按模型';

  @override
  String get byPopularity => '按热度';

  @override
  String get byProject => '按项目';

  @override
  String get byRequest => '按请求';

  @override
  String get byTime => '按时间';

  @override
  String get byTool => '按工具';

  @override
  String get cache => '缓存';

  @override
  String get cacheHit => '缓存命中';

  @override
  String cacheHit0(Object? periodLabel) => '$periodLabel缓存命中';

  @override
  String get cacheRead => '读缓存';

  @override
  String get cacheReadsNewInputCacheReadsHigher => '读缓存 ÷（新输入 + 读缓存）。越高越省钱。';

  @override
  String get cacheSavings => '缓存帮你省了';

  @override
  String get cacheSavings2 => '缓存帮你省了  ⓘ';

  @override
  String get cacheWrite => '写缓存';

  @override
  String get cacheWrite1h => '写缓存（存 1 小时）';

  @override
  String get cacheWrite5m => '写缓存（存 5 分钟）';

  @override
  String get cacheWriteShort => '写缓存（短时）';

  @override
  String get cachedArticlesAreStillAvailableYouCan => '已有内容保留，可随时再次刷新。';

  @override
  String calendarDay(int month, int day) => '$month月$day日';

  @override
  String calendarDayWeekdayWithYear(
    int year,
    int month,
    int day,
    int weekday,
  ) => '$year年${calendarDayWithWeekday(month, day, weekday)}';

  @override
  String calendarDayWithWeekday(int month, int day, int weekday) =>
      '${calendarDay(month, day)} ${shortWeekday(weekday)}';

  @override
  String calendarDayWithYear(int year, int month, int day) =>
      '$year年$month月$day日';

  @override
  String calendarMonth(int year, int month) => '$year年$month月';

  @override
  String get cancel => '取消';

  @override
  String get cancelRefresh => '取消刷新';

  @override
  String get canceled => '已取消';

  @override
  String get canceling => '正在取消';

  @override
  String get cancelingRefresh => '正在取消刷新…';

  @override
  String get cannotReadLogDirectory => '没有权限读取日志目录';

  @override
  String chartSpanningSessions(Object? tokens, Object? unit) =>
      '另有 $tokens token 来自跨$unit的会话快照，不在图里；上面的用量已经算上了。';

  @override
  String chartUnallocatedUsage(
    Object? tokens,
    Object? spanUnit,
    Object? bucketUnit,
  ) => '另有 $tokens token 来自跨$spanUnit的会话快照，没法按$bucketUnit拆开，不在图里；上面的总量已经算上了。';

  @override
  String get checkAutomaticallyOnceADay => '每天自动检查一次';

  @override
  String get checkForUpdates => '检查更新';

  @override
  String checkedAt(Object? time) => '$time 检查过';

  @override
  String get checkedAgainstPublicReferencesAndSamplesReport =>
      '格式按公开资料和样例确认，大概率没问题；对不上的话可以反馈。';

  @override
  String get checkedAgainstRealUsageLogs => '拿真实使用的日志逐条对过，数字可靠。';

  @override
  String get checkedAgainstTheProviderSPricingPage => '和厂商价格页逐项对过。';

  @override
  String get checkedWithSampleLogs => '只用样例日志核对过';

  @override
  String get checking => '正在检查…';

  @override
  String get checks => '自检';

  @override
  String get checksPassed => '自检正常';

  @override
  String get chinaStandardTimeUtc8 => '北京时间（UTC+8）';

  @override
  String get chinese => '中文';

  @override
  String get chineseLanguage => '中文';

  @override
  String get clear => '清空';

  @override
  String get clearFilters => '清除筛选';

  @override
  String get clearSearch => '清除搜索';

  @override
  String get close => '关闭';

  @override
  String get closeNavigationMenu => '关闭导航菜单';

  @override
  String closePanel(String label) => '关闭$label';

  @override
  String get cny => '人民币 ¥';

  @override
  String get community => '社区';

  @override
  String conditionalPriceTableLabel(Object? value) => '$value 条件价格';

  @override
  String get cost => '金额';

  @override
  String get costsAreEstimatesAtEachModelS3 =>
      '金额是按各模型的公开价算出来的，用来比较和感知，不是你的账单。用套餐的话，实际花费通常更低。';

  @override
  String couldNotAccessLogDirectoriesFor0(Object? count) =>
      '有 $count 个工具的日志目录没有权限读取，见下方。其余支持的工具没在这台电脑上找到。';

  @override
  String get couldNotCancelWaitForTheCurrent => '取消请求失败，请等待当前刷新结束。';

  @override
  String syncStatusReadFailed(Object? failure) => '无法确认同步状态：$failure';

  @override
  String get couldNotLoadRequestFailed => '加载失败（request_failed）';

  @override
  String exportFolderOpenFailed(Object? error) => '打开文件夹失败：$error';

  @override
  String get couldNotOpenTheArticleCheckYour => '无法打开原文，请检查默认浏览器设置。';

  @override
  String get couldNotOpenTheContainingFolder => '无法打开所在文件夹';

  @override
  String get couldNotParse => '解析失败';

  @override
  String get couldNotParseThisSourceCachedArticles => '来源内容无法解析，本次未更新缓存。';

  @override
  String get couldNotReachTheSourceCheckYour => '无法连接来源，请检查网络后重试。';

  @override
  String get couldNotReadLocalStatusAfterRefresh => '刷新结束后无法读取本地状态，可尝试再次手动刷新。';

  @override
  String get couldNotReadOrSaveLocalStatus =>
      '本机状态文件无法读取或保存，条目照常显示；这次的标记可能不会保留。';

  @override
  String get couldNotReadTheLocalCacheTry => '本地缓存读取失败，可尝试手动刷新。';

  @override
  String get couldNotSaveReadStatus => '已读状态保存失败。';

  @override
  String get couldNotSaveSourceSettings => '来源设置保存失败。';

  @override
  String get couldNotSaveStarredStatus => '收藏状态保存失败。';

  @override
  String exchangeRateUpdateFailed(Object? failure) => '汇率更新失败：$failure';

  @override
  String get counting => '统计中…';

  @override
  String get currency => '货币';

  @override
  String get currencyUsedToDisplayCosts => '金额用什么显示';

  @override
  String get custom => '自定义';

  @override
  String get dailyAverage => '日均用量';

  @override
  String get dailyUsageForThisSessionTodayIs => '这个会话每天用了多少；今天高亮';

  @override
  String get dark => '深色';

  @override
  String get dataDirectory => '数据目录';

  @override
  String get date => '日期';

  @override
  String get day => '天';

  @override
  String dayCount(Object? streak) => '$streak 天';

  @override
  String daysAgo(Object? days) => '$days 天前';

  @override
  String get debugRunsRequireTokenLensPreviewData =>
      '调试运行需要同时设置 TOKEN_LENS_PREVIEW_DATA_DIR 和 TOKEN_LENS_PREVIEW_HOME 为独立的绝对目录。';

  @override
  String get deprecation => '弃用';

  @override
  String get diagnosticsAbout => '诊断与关于';

  @override
  String get didNotUpdate => '未更新';

  @override
  String get disable => '停用';

  @override
  String get disabled => '已停用';

  @override
  String get dismissThisVersion => '这个版本不再提示';

  @override
  String get display => '显示';

  @override
  String get displayOnlyLedgerAmountsStayTheSame =>
      '只换显示，账本里的金额不变。汇率只在点「更新汇率」时联网取一次，失败就保留现在的值。';

  @override
  String get displayPreferencesAndHowCostsAreCalculated => '数字怎么显示，金额怎么算。';

  @override
  String get duration => '时长';

  @override
  String get eachRequestIncludesItsTimeModelAnd => '能看到每次请求的时间、模型和用量。';

  @override
  String get eachSquareIsADayDarkerSquares => '每个格子是一天，颜色越深用得越多';

  @override
  String emptyPeriodHint(Object? period) =>
      '$period还没有用量。换个时间范围看看，或者等工具产生新的日志后再同步。';

  @override
  String get enable => '启用';

  @override
  String get enableOrDisableSourcesAndCheckRefresh => '启停来源、查看每个来源的刷新状态';

  @override
  String get enabledSourcesHaveNoArticlesToShow =>
      '已启用的来源暂时没有可显示的动态，程序会每 30 分钟自动刷新。';

  @override
  String get englishLanguage => 'English';

  @override
  String get enterAValidDateRange => '请填写有效的日期范围';

  @override
  String get estCost => '约值';

  @override
  String estCost0(Object? periodLabel) => '$periodLabel约值';

  @override
  String estCost02(Object? value) => '$value约值 ';

  @override
  String get estimatedCostPrefix => '约值 ';

  @override
  String get estimatedAtListPrices => '按公开标准价估算，不是账单';

  @override
  String get estimatedFromLogTimestamps => '按日志时间戳估算';

  @override
  String get estimatedFromReasoningStartEvents => '按推理开始事件估算';

  @override
  String get estimatedFromWeeklyShare => '周占比估算';

  @override
  String get estimatedPrice => '估算价';

  @override
  String get evidence => '证据等级';

  @override
  String example0(Object? value) => '例：$value';

  @override
  String exchangeRate(Object? rate, Object? updated) =>
      '1 美元 ≈ $rate 元 · $updated';

  @override
  String get exportDiagnostics => '导出诊断日志';

  @override
  String diagnosticsExportFailed(Object? error) => '导出失败：$error';
  @override
  String get export => '导出';
  @override
  String get exportCsv => '导出 CSV';
  @override
  String get exportJson => '导出 JSON';
  @override
  String get includeFullProjectPaths => '包含完整项目路径';
  @override
  String exportCompleted(String name) => '已导出 $name';

  @override
  String get exporting => '正在导出…';

  @override
  String newsFetchProgress(Object? completed, Object? total) =>
      '正在获取动态 · 已完成 $completed/$total 个来源';

  @override
  String get filterBySourceAndType => '按来源和类型筛选';

  @override
  String get firstToken => '首字';

  @override
  String get firstToken2 => '首字 ';

  @override
  String get firstTokenWaitForTheReply => '首字（开始回复前要等）';

  @override
  String get followSystem => '跟随系统';

  @override
  String get found => '找到';

  @override
  String get foundTheLogDirectoryButCouldNot =>
      '找到了日志目录，但没有权限读取。检查文件夹权限后点「重新检测」。';

  @override
  String get fri2 => '周五';

  @override
  String get from => '起始';

  @override
  String get fullSessionTotal => '整个会话累计';

  @override
  String get generalNoLabel => '常规（无标签）';

  @override
  String get getANoticeWhenANewVersion =>
      '有新版本时提示你，去 GitHub 的发布页下载。程序不会自己下载或安装。';

  @override
  String get githubStars => 'GitHub 星数';

  @override
  String noonGreeting(int hour) => '中午好';

  @override
  String get goodAfternoon2 => '下午好';

  @override
  String get goodEvening => '晚上好';

  @override
  String get goodMorning => '早上好';

  @override
  String get groupBy => '拆分方式';

  @override
  String get hackerNewsPoints => 'Hacker News 票数';

  @override
  String get handled => '已处理';

  @override
  String get highestFirst => '从大到小';

  @override
  String holidayCountAndEnd(Object? days, Object? lastDate) =>
      '（$days 天，最晚 $lastDate）';

  @override
  String holidayPricingNote(Object? holidays, Object? range) =>
      '$holidays$range；未登记年份仍按星期和时段判断。';

  @override
  String holidaysListedThrough0(Object? value) => '节假日仅登记到 $value年';

  @override
  String get hour => '小时';

  @override
  String hourTick(Object? value) => '$value时';

  @override
  String hoursAndMinutesDuration(Object? value1, Object? value2) =>
      '$value1 小时 $value2 分';

  @override
  String daysAndHoursDuration(int days, int hours) =>
      hours == 0 ? '$days 天' : '$days 天 $hours 小时';

  @override
  String get howLargeNumbersAreShortened => '大数字怎么缩写';

  @override
  String get howPricesWork => '价格怎么算';

  @override
  String get huggingFaceLikes => 'Hugging Face 点赞';

  @override
  String get huggingFacePaperUpvotes => 'Hugging Face 论文点赞';

  @override
  String get ifUsageLooksWrongSyncFailsOr =>
      '遇到统计不对、同步报错或者应用卡住时，导出一份诊断日志发给维护者。';

  @override
  String includes0LocalRecordZeroCost(Object? count) =>
      '其中 $count 条本地 · 金额按 0 计';

  @override
  String get includesAllUsage => '不受筛选影响';

  @override
  String get includesAppAndSystemVersionsResultsAnd =>
      '包含：应用和系统版本、最近 10 次同步的结果和全部异常、各工具找到的日志文件数和路径、最近 7 天的运行日志。\n不包含：账本、任何对话内容。用户目录会显示成 ~。';

  @override
  String get incompletePromptLengthBaseTier => '提示长度不完整 · 基础档';

  @override
  String inputOutputPrices(Object? input, Object? output) =>
      '输入 $input · 输出 $output';

  @override
  String get installAndUseASupportedToolThen => '装上并用过一次以后，点「立即同步」就会出现在上面。';

  @override
  String get interfaceLanguage => '界面语言';

  @override
  String invalidUpdateCheckResponse(Object? checked, Object? retry) =>
      'GitHub 返回的内容读不懂 · $checked。$retry';

  @override
  String get justNow => '刚刚';

  @override
  String get knownLimitations => '要知道的';

  @override
  String get last20Weeks => '最近 20 周';

  @override
  String get lastMonth => '上个月';

  @override
  String lastSuccessfulRefresh0(Object? value) => '上次成功：$value';

  @override
  String get lastSyncDetails => '上次同步的技术细节';

  @override
  String lastUsed0(Object? value) => '最近一次使用 $value · ';

  @override
  String get lastWeek => '上周';

  @override
  String get latest => '最新';

  @override
  String get ledgerPath => '账本路径';

  @override
  String get less => '少';

  @override
  String get light => '浅色';

  @override
  String get lightDarkOrSystemTheme => '浅色、深色或跟着系统走';

  @override
  String get likes => '赞';

  @override
  String listPriceWithUnpricedRecords(Object? count) => '按公开价估算 · $count 条未计价';

  @override
  String get listSeparator => '、';

  @override
  String get loadMore => '加载更多';

  @override
  String get loading => '正在加载';

  @override
  String get loadingSession => '正在读取会话…';

  @override
  String get loadingUsageForThisPeriod => '正在读取本期用量…';

  @override
  String get local => '本地';

  @override
  String get localProviderZeroCost => '本地提供方，金额按 0 计';

  @override
  String logFileCount(Object? value) => '$value 个日志文件';

  @override
  String get logRetention => '日志留存';

  @override
  String logsGone(Object? value) => '另有 $value 条的日志已经不在了，照常计入总数，但没法再复核。';

  @override
  String longContextPrompt0Tokens(Object? count) => '长上下文（提示 > $count token）';

  @override
  String longContextSummary(Object? threshold, Object? count) =>
      '超过 $threshold token 的长提示按更高价算：$count 次';

  @override
  String get longContextTiers => '长上下文分档';

  @override
  String get longestStreak => '最长连续';

  @override
  String longestStreakDays(Object? streak) => '最长连续 $streak 天';

  @override
  String get lowestFirst => '从小到大';

  @override
  String get manageSources => '管理来源';

  @override
  String get markAllAsRead => '全部标为已读';

  @override
  String get markAsRead => '标为已读';

  @override
  String get markAsUnread => '标为未读';

  @override
  String get markThisDayAsRead => '本日标为已读';

  @override
  String minutesDuration(Object? minutes) => '$minutes 分钟';

  @override
  String missingFromLogs0(Object? missing) => '日志里没记：$missing';

  @override
  String get model => '模型';

  @override
  String modelCount(Object? models) => '$models 个模型';

  @override
  String get modelNotLogged => '没写模型';

  @override
  String get modelsAppearHereAfterSyncingToolLogs => '同步之后，出现过的模型会逐条列在这里。';

  @override
  String get modelsUsed => '用了哪些模型';

  @override
  String get mon2 => '周一';

  @override
  String get month => '月';

  @override
  String get month2 => '个月';

  @override
  String get more => '多';

  @override
  String moreActionsFor0(Object? name) => '$name 的更多操作';

  @override
  String get mostTokensAreReusedContextWhichCosts => '大部分是重复发送的上下文，命中缓存后便宜很多';

  @override
  String get mostUsed => '用得最多';

  @override
  String get mostlyPerRequest => '大多按请求记录';

  @override
  String get needsReview => '待查';

  @override
  String get neverChecked => '还没检查过';

  @override
  String get neverCheckedAutomaticChecksOff => '还没检查过 · 自动检查已关';

  @override
  String get neverRefreshed => '还没刷新过';

  @override
  String get newArticlesWillAppearAfterTheNext => '新动态会在下次刷新后出现在这里。';

  @override
  String get newInput => '新输入';

  @override
  String get newInputIsContentSentToThe =>
      '新输入：这次新发给模型的内容 · 输出：模型写回来的 · 读缓存：重复发送、命中缓存的上下文，便宜很多 · 写缓存：第一次写进缓存的内容。四类互不重叠，加起来就是用量。';

  @override
  String newVersion(Object? version) => '有新版本 $version';

  @override
  String get news => '资讯';

  @override
  String newsItemsSummary(Object? count, Object? unreadSuffix) =>
      '$count 条$unreadSuffix';

  @override
  String newsRefreshSummary(Object? count, Object? lastRefresh) =>
      '$count 个来源 · $lastRefresh · 每 30 分钟自动刷新';

  @override
  String get noArticlesYet => '还没有动态';

  @override
  String get noDailyRecords => '没有按天记录';

  @override
  String get noHolidaysListed => '尚未登记节假日';

  @override
  String get noIndividualRequestsInThisPeriod => '本时段没有逐次请求';

  @override
  String get noIndividualRequestsInThisPeriodTools =>
      '这段时间没有逐次请求。只记录会话总数的工具不出现在这里。';

  @override
  String get noListPrice => '没有公开价';

  @override
  String get noLogsFoundForSupportedToolsOn =>
      '这台电脑上还没找到支持的工具的日志。装好并用过其中任意一个后再回来。';

  @override
  String get noMatchingArticles => '没有符合条件的动态';

  @override
  String get noModelsUsedYet => '还没有用到的模型';

  @override
  String get noPopularityDataForTheseResults => '当前结果没有热度数据，暂不能按热度排序。';

  @override
  String get noPricingYet => '还没有价格';

  @override
  String get noProjectLogged => '没有记录项目';

  @override
  String noReleaseCheckResult(Object? time) => 'GitHub 上还没有正式发布的版本 · $time 检查过';

  @override
  String get noRequestsInThisPeriodHaveTiming => '这段时间的请求都没有计时记录。';

  @override
  String get noSessionsYet => '还没有会话';

  @override
  String get noStarredArticles => '还没有收藏';

  @override
  String get noSuccessfulRefreshYet => '尚无成功刷新记录';

  @override
  String get noSyncHistory => '还没有同步记录';

  @override
  String get noSyncYet => '还没有同步过';

  @override
  String get noToolLogsFoundYet => '还没找到工具的日志';

  @override
  String get noUsage => ' · 没有用量';

  @override
  String get noUsage2 => '没有用量';

  @override
  String noUsageForPeriod(Object? label) => '$label还没有用量';

  @override
  String get noUsageMatchesTheseFiltersInThis => '这段时间没有符合筛选的用量。';

  @override
  String noUsageRecordedFor0ToCompare(Object? comparison) =>
      '$comparison还没有记录，没法比。';

  @override
  String get noUsageYet => '还没有任何用量';

  @override
  String get notLogged => '不记录';

  @override
  String get nothingIsCachedYetTheAppRefreshes =>
      '本地还没有缓存。程序开着时每 30 分钟自动刷新，也可以现在刷新。';

  @override
  String get numberUnits => '数字单位';

  @override
  String get offPeak => '低谷';

  @override
  String get offPeakPricingAppliesAtOtherTimes =>
      '其余时段与已登记节假日全天按低谷价；周末补班日按周末计。';

  @override
  String offPeakSummary(Object? count) => '按时段计价：$count 次在低谷时段';

  @override
  String get official => '官方';

  @override
  String get officialPrice => '已对照官方价';

  @override
  String get officialPricingPage => '官方价格页';

  @override
  String get offline => '离线';

  @override
  String get onDaysWithUsage => '按有用量的天算';

  @override
  String get onePerRequest => '，每次请求一条';

  @override
  String get oneRowPerRequestSelectARow => '每个请求一行，点一行打开它所在的会话。';

  @override
  String get onlyASessionTotalIsLoggedCounted => '只记录总数，算在开始那天';

  @override
  String openArticleInDefaultBrowser0(Object? title) => '在默认浏览器中打开原文：$title';

  @override
  String get openContainingFolder => '打开所在文件夹';

  @override
  String get openDownloadPage => '打开下载页';

  @override
  String get openNavigationMenu => '打开导航菜单';

  @override
  String get openingTheLocalNewsCache => '正在打开本地新闻缓存…';

  @override
  String outOfDays(Object? elapsed) => ' / $elapsed 天';

  @override
  String get output => '输出';

  @override
  String get outputTokensDividedByTotalRequestTime =>
      '整次请求的输出 token 除以总耗时，等待时间也算在内，所以通常比“速度”低。';

  @override
  String get over100MillionTokensInOneRequest => '单次请求超过 1 亿 token';

  @override
  String get overview => '概览';

  @override
  String get overview2 => '概况';

  @override
  String get overviewComparisonEqualLink => '和';

  @override
  String overviewComparisonLead(
    String period,
    String comparison,
    String relation,
  ) => '$period$relation$comparison';

  @override
  String get overviewComparisonOtherLink => '比';

  @override
  String overviewComparisonTail(String relation, String comparison) => '，';

  @override
  String get overviewHigher => '用得多';

  @override
  String get overviewLower => '用得少';

  @override
  String get overviewMajorityLead => '大部分花在 ';

  @override
  String get overviewMajorityTail => ' 上';

  @override
  String get overviewMuchHigher => '用得多了不少';

  @override
  String get overviewMuchLower => '少了不少';

  @override
  String get overviewSecondToolLead => '，其次是 ';

  @override
  String get overviewSentenceEnd => '。';

  @override
  String get overviewSimilar => '差不多';

  @override
  String get overviewTopToolLead => '用得最多的是 ';

  @override
  String overviewTrackingSince(String date) => '从 $date开始记录，';

  @override
  String get pageNavigation => '页面导航';

  @override
  String get pastYear => '这一年';

  @override
  String get peak => '高峰';

  @override
  String get peakAndOffPeak => '峰谷分时';

  @override
  String peakHourShare(Object? tokens, Object? share) =>
      '$tokens token，占今天的 $share';

  @override
  String get perMillionTokens => '每百万 token';

  @override
  String get perRequest => '每次请求都有记录';

  @override
  String get perRequest2 => '每次请求';

  @override
  String get perRequestEstimatesBasedOnLogTimestamps =>
      '按每次请求统计，数字是从日志时间推算的约值。';

  @override
  String get perTurn => '每轮对话';

  @override
  String get period => '周期';

  @override
  String get periodAllTime => '全部时间';

  @override
  String periodUsage(Object? value) => '$value用量';

  @override
  String get popular => '热度';

  @override
  String get priceUnavailable => '查不到价格';

  @override
  String get priceUnverified => '待核价';

  @override
  String get pricing => '价格';

  @override
  String get addPrice => '填写价格';

  @override
  String get manualPriceIntro =>
      '这个模型不在价格表里。知道它的价格的话可以自己填，填的价只存在这台电脑上，标为「手填」，随时能改或删。';

  @override
  String manualPriceSubtitle(String model, String tool, String n) =>
      '$model · 来自 $tool · $n 条记录';

  @override
  String get copyPricesFrom => '照已有模型的价格填';

  @override
  String get copyPricesNone => '不用，自己填';

  @override
  String get copyPricesHelp => '它其实是别的模型换了个名字时用，比如接入方自定义的模型名。';

  @override
  String get copyBaseOnlyTag => '只复制基础价';

  @override
  String copiedPriceSource(String id) => '照 $id 的官方价';

  @override
  String get manualUsd => '美元 \$';

  @override
  String get manualCny => '人民币 ¥';

  @override
  String get manualOptional => '可不填';

  @override
  String get manualNewInput => '新输入';

  @override
  String get manualCacheRead => '缓存读';

  @override
  String get manualCacheWrite => '缓存写';

  @override
  String get manualPriceUnit => '每百万 token 的价格。可不填的项留空，这部分 token 不计金额。';

  @override
  String get manualSource => '价格出处';

  @override
  String get manualSourceHint => '价格页地址，或者一句备注';

  @override
  String manualEstimatePending(String n) => '填好输入和输出价格后，这里会显示 $n 条记录一共会算出多少金额。';

  @override
  String manualEstimate(String n, String amount, String parts) =>
      '保存后，这 $n 条记录按这个价算，约 $amount${parts.isEmpty ? '' : '（$parts）'}。';

  @override
  String get manualNoCacheRead => '缓存读留空，这部分 token 不计金额。';

  @override
  String manualSavedAtRate(String rate) =>
      '按 1 美元 ≈ $rate 元折成美元保存，以后汇率变了也不跟着变。';

  @override
  String get manualPriceFootnote => '以后价格表有了这个模型的价，仍按你手填的算，会提示你可以改用价格表的价。';

  @override
  String get manualPriceRequired => '输入和输出价格要填。';

  @override
  String get manualPriceNonnegative => '价格只能填 0 或正数。';

  @override
  String get saveManual => '保存';

  @override
  String get manualBadge => '手填';

  @override
  String get manualBadgeTooltip => '按你手填的价算';

  @override
  String get manualPriceState => '你自己填的价，只存在这台电脑上';

  @override
  String unpricedFillHelp(String n) => '知道它的价格的话，自己填上，这 $n 条记录就有金额了。';

  @override
  String manualPriceCreated(String date) => '你在 $date 填的价，只存在这台电脑上。';

  @override
  String manualConverted(String rate) => '按 1 美元 ≈ $rate 元折成美元计算。';

  @override
  String manualSourceNote(String note) => '出处：$note';

  @override
  String get editManualPrice => '修改';

  @override
  String get removeManualPrice => '删除手填价';

  @override
  String get removeManualTitle => '删除手填价？';

  @override
  String removeManualBody(String model, String n) =>
      '删除后，$model 的 $n 条记录回到「未定价」，不再计入金额。';

  @override
  String get removeManualConfirm => '删除';

  @override
  String manualListPrice(String input, String output) =>
      '价格表现在也有这个模型的官方价（输入 $input · 输出 $output）。现在仍按你手填的价算。';

  @override
  String get useListPrice => '改用价格表的价';

  @override
  String pricingCatalogRow(String date, String source) =>
      '价格表：$date版 · $source';

  @override
  String get pricingCatalogOnline => '联网更新';

  @override
  String get pricingCatalogBuiltin => '程序自带';

  @override
  String pricingCatalogManual(String n) => '手填 $n 个模型';

  @override
  String get pricingOnlineSettings => '联网更新设置 ›';

  @override
  String get addMissingPrices => '去补价格 ›';

  @override
  String get autoUpdatePricingLabel => '自动更新价格表';

  @override
  String get autoUpdatePricingHelp =>
      '每天向 raw.githubusercontent.com 下载本项目核对过的价格表，只下载，不上传任何数据。关掉后只用程序自带的价格表。';

  @override
  String pricingUsingDate(String date) => '正在用 $date版价格表';

  @override
  String pricingCheckedAt(String time) => '$time 检查过';

  @override
  String get pricingUpdateNow => '立即更新';

  @override
  String get pricingChecking => '正在检查…';

  @override
  String pricingUpdated(String date, String n) =>
      '已更新到 $date版。新增 $n 个模型的价格，历史金额已按新价重算。';

  @override
  String pricingUpdatedNoNew(String date) => '已更新到 $date版，历史金额已按新价重算。';

  @override
  String get pricingOffline => '没更新成功，连不上 GitHub。';

  @override
  String get pricingLimited => '没更新成功，GitHub 暂时拒绝了请求。';

  @override
  String get pricingInvalid => '没更新成功，下载到的价格表读不懂。';

  @override
  String pricingStillUsing(String date) => '继续用 $date版，明天再试。';

  @override
  String pricingDisabled(String date) => '只用程序自带的 $date版价格表。';

  @override
  String pricingAboutOnline(String date, String version, String builtin) =>
      '联网 $date版 · $version（内置 $builtin版）';

  @override
  String pricingAboutBuiltin(String date, String version) =>
      '内置 $date版 · $version';

  @override
  String get pricingIsUnavailableForThisModel => '该模型没有可用价格';

  @override
  String get pricingIsUnpublishedOrUnverifiedEstimatedFrom =>
      '厂商没单独公布，或者还没核对，按同类模型估算';

  @override
  String get pricingSettings => '价格与设置';

  @override
  String get pricingVersion => '价格表版本';

  @override
  String get project => '项目';

  @override
  String prompt0Tokens(Object? count) => '提示 > $count token';

  @override
  String get promptLengthIncludesNewInputCacheReads =>
      '提示长度含新输入、缓存读和缓存写；恰好等于门槛仍用较低档。累计快照用基础档。提示长度不完整且已知部分未超过门槛时，用基础档并标记。';

  @override
  String get pts => '票';

  @override
  String publishedAt0(Object? value) => '发布时间：$value';

  @override
  String publishedOn0(Object? value) => '发布日期：$value';

  @override
  String get rankedByThisSource => '按该来源自带的热度';

  @override
  String get rateLimited => '限流';

  @override
  String rateLimitedUpdateCheck(Object? time) =>
      'GitHub 暂时拒绝了请求（同一网络下请求太多）· $time。过一会儿再试。';

  @override
  String rateUpdatedAt(int month, int day, String hour, String minute) =>
      '$month/$day $hour:$minute 更新';

  @override
  String get readAndStarredStatusUnavailable => '已读和收藏暂不可用';

  @override
  String get reading => '读取中…';

  @override
  String get readingLogs => '正在读取日志…';

  @override
  String onboardingReading(int read, int total) =>
      '正在读取日志… 已读 $read / $total 个文件';

  @override
  String get onboardingOrganizing => '日志读完了，正在整理统计…';

  @override
  String onboardingElapsed(int minutes, int seconds) =>
      '已用 $minutes 分 $seconds 秒';

  @override
  String get onboardingTimeHint => '日志多的话，第一次统计可能要几分钟。以后打开只读新增的部分，会快很多。';

  @override
  String get onboardingToolDone => '已读完';

  @override
  String onboardingToolReading(int read, int total) => '读取中 $read / $total';

  @override
  String get onboardingToolWaiting => '等待中';

  @override
  String get onboardingContinueHint =>
      '不用等，可以先去看看，统计会在后台继续；\n关掉窗口也没关系，下次打开会接着读。';

  @override
  String get readsLogsOnThisComputerAndLeaves => '只读取本机日志，不上传任何内容，也不改动这些工具。';

  @override
  String get recentSessions => '最近会话';

  @override
  String recordCount(Object? count) => '$count 条';

  @override
  String get recordType => '记录方式';

  @override
  String get records => '记录';

  @override
  String get recordsComplete => '记录完整';

  @override
  String recordsNoun(int count) => '条记录';

  @override
  String recordsProcessed(
    Object? attempted,
    Object? inserted,
    Object? updated,
    Object? unchanged,
    Object? rejected,
  ) =>
      '处理了 $attempted 条记录：新增 $inserted 条，有变化的 $updated 条，没变的 $unchanged 条，跳过 $rejected 条。';

  @override
  String get recordsWithoutPricesAreExcludedFromCost =>
      '没有价格的记录不计入金额。到「价格与设置」里查看是哪些模型。';

  @override
  String get refreshAll => '全部刷新';

  @override
  String get refreshCanceled => '刷新已取消';

  @override
  String get refreshFailedShowingCachedNews => '刷新失败 · 正在查看离线缓存';

  @override
  String get refreshFailedTryAgainShortly => '刷新失败，请稍后重试。';

  @override
  String get refreshNow => '立即刷新';

  @override
  String refreshProgress(Object? completed, Object? total) =>
      '正在刷新 · 已完成 $completed/$total 个来源';

  @override
  String get refreshThisSource => '刷新此来源';

  @override
  String refreshed0(Object? value) => '$value 刷新';

  @override
  String get refreshesEvery30MinutesWhileOpenRate =>
      '程序开着时每 30 分钟刷新一次；被限流就跳过下一轮。';

  @override
  String get refreshing => '正在刷新';

  @override
  String get refreshing2 => '刷新中…';

  @override
  String get release => '版本';

  @override
  String releaseDatePrefix(Object? value) => '$value发布 · ';

  @override
  String remainingTools(Object? value1, Object? value2) =>
      '另有 $value1，合计 $value2';

  @override
  String remove0Filter(Object? label) => '去掉$label筛选';

  @override
  String requestCount(Object? value) => '$value 次请求';

  @override
  String requestCountSuffix(int count) => ' 次请求';

  @override
  String get requestFailed => '请求失败';

  @override
  String requestFailed0(Object? failure) => '请求失败：$failure';

  @override
  String get requests => '请求';

  @override
  String requests0(Object? periodLabel) => '$periodLabel请求';

  @override
  String get rereadAllLogs => '重新读取全部日志';

  @override
  String get rereadAllLogsWithoutUsingThePrevious =>
      '忽略上次的读取结果，把全部日志重新读一遍。怀疑统计漏了或不对时使用；账本里已有的用量不会被删除。';

  @override
  String get rereading => '重新读取中…';

  @override
  String get responseTooLarge => '响应过大';

  @override
  String get retry => '重试';

  @override
  String get retryLoading => '重试读取';

  @override
  String retryingAt0(Object? value) => '将在 $value 自动重试';

  @override
  String reviewableRecords(Object? value) => '$value 条还能对照原始日志复核';

  @override
  String get sat2 => '周六';

  @override
  String savedTo0(Object? exportPath) => '已保存到：$exportPath';

  @override
  String get scanAgain => '重新检测';

  @override
  String get schemaVersion => 'schema 版本';

  @override
  String get scrollableTableOfConditionalPrices => '条件价格表，可横向滚动';

  @override
  String get searchTitlesAndSummaries => '搜索标题和摘要';

  @override
  String secondsDuration(Object? value) => '$value 秒';

  @override
  String get seeHowManyTokensYourAiCoding => '看看你的 AI 编程工具用了多少 token、按公开价值多少钱。';

  @override
  String selectABarForThat0S(Object? unit) => '。点柱子看那$unit的明细';

  @override
  String selectABarToFilterToThat(Object? unit) => '。点柱子只看那$unit';

  @override
  String get selectARowForCachePricesAnd => '点一行看缓存价格和说明。价格表随软件内置，不联网也能用。';

  @override
  String get selectARowToAddItTo => '点一行，把它加进筛选';

  @override
  String get selectTheStarNextToAnArticle => '在条目右侧点星标收藏；来源不再列出它以后，收藏也会保留。';

  @override
  String selectToViewThis0SBreakdown(Object? value) => '点一下看这$value的明细';

  @override
  String get selectedPeriod => '所选时段';

  @override
  String get selectedPeriodInSentence => '这段时间';

  @override
  String get sentenceSeparator => '；';

  @override
  String get session => '会话';

  @override
  String get sessionDetails => '会话详情';

  @override
  String sessionForTool(String tool) => '$tool 会话';

  @override
  String sessionHeading(
    Object? tool,
    Object? date,
    Object? time,
    Object? duration,
  ) => '$tool · $date $time 开始 · 持续 $duration';

  @override
  String get sessionId => '会话 ID';

  @override
  String sessionRecordSummary(Object? count, Object? description) =>
      '$count 条$description';

  @override
  String get sessionSnapshotBaseTier => '累计快照 · 基础档';

  @override
  String sessionSpan(Object? duration, Object? days) => '$duration · 跨 $days 天';

  @override
  String get sessionTotalsOnly => '只记录总数';

  @override
  String get sessionTotalsOnly2 => '只记录每个会话的总数';

  @override
  String get sessionUnavailable => '会话不存在';

  @override
  String get sessionUsageIsAvailableRequestTimesAre =>
      '能看到每个会话用了多少，看不到会话里每次请求的时间。';

  @override
  String get sessions => '会话';

  @override
  String sessions0(Object? value) => '$value的会话';

  @override
  String get sessionsNavigation => '会话记录';

  @override
  String get sessionsAppearHereAfterSyncingToolLogs => '同步之后，工具记录的每个会话都会出现在这里。';

  @override
  String get sessionsMixingBothRecordTypes => '同一会话混用两种记录方式';

  @override
  String sessionsNoun(int count) => '个会话';

  @override
  String sessionsWithUsageIn0SortedBy(Object? periodLabel) =>
      '$periodLabel有用量的会话，按时段内用量排序。累计是整个会话的总数。';

  @override
  String get settings => '设置';

  @override
  String get share => '占比';

  @override
  String get shareOfInputServedFromCache => '输入里走缓存的比例';

  @override
  String shortMonth(int month) => '$month月';

  @override
  String shortWeekday(int weekday) => '周${'日一二三四五六'[weekday % 7]}';

  @override
  String show0More(Object? value) => '再显示 $value 条';

  @override
  String show30More0Left(Object? value) => '再显示 30 条（还有 $value 条）';

  @override
  String showing0Session(Object? count) => '已显示 $count 个会话';

  @override
  String skipped0FileFromToolsWithNo(Object? skippedFiles) =>
      '另有 $skippedFiles 个文件所在的工具没有任何变化，这次没有重新处理。';

  @override
  String get slowerThan90OfRequestsHere => '比这里九成请求都慢';

  @override
  String get someSessionsHaveOnlyATotalAnd => '有的会话只有一条总数，这些会话看不到时间线。';

  @override
  String get sort => '排序';

  @override
  String sortBy0(Object? value) => '排序：$value';

  @override
  String sortedBy0HighestFirstItemsWithout(Object? unit) =>
      '按 $unit 降序；无热度排在最后，同热度按时间。';

  @override
  String get sortedByUsageInThisPeriod => '按这段时间的用量排序';

  @override
  String get source => '来源';

  @override
  String source0(Object? sourceName) => '来源 $sourceName';

  @override
  String sourceCheckLabel(String check, String count) => '$check：$count';

  @override
  String sourceCheckRecordCount(int count) => '$count 条';

  @override
  String sourceCheckSessionCount(int count) => '$count 个会话';

  @override
  String get sourceId => '来源 ID';

  @override
  String sourceRecordCount(Object? value) => '$value 条记录';

  @override
  String sourcesIntro(Object? found) =>
      '${found}Token Lens 只读它们的日志，不上传，也不改动这些工具。';

  @override
  String sourcesNotUpdated(Object? failed) => '$failed 个来源没更新';

  @override
  String get speed => '速度';

  @override
  String get speed2 => '速度 ';

  @override
  String get speedTokenS => '速度 token/s';

  @override
  String get speedTokensPerSecondWhileReplying => '速度（回复时每秒出多少）';

  @override
  String get star => '收藏';

  @override
  String get starred => '收藏';

  @override
  String starred0(Object? starred) => '收藏 $starred';

  @override
  String get stars => '星';

  @override
  String get start => '开始';

  @override
  String get startCounting => '开始统计';

  @override
  String sessionStartLabel(Object? value) => '$value 开始';

  @override
  String startedOn(String date) => '开始于 $date';

  @override
  String get status => '状态';

  @override
  String get stillUpLate => '夜深了';

  @override
  String get subscription => '套餐';

  @override
  String get subscriptionsAreBilledSeparately => ' 用套餐时不按这个价扣费。';

  @override
  String get sun2 => '周日';

  @override
  String get supported => '已接入';

  @override
  String supportedToolCount(Object? supported) => '支持 $supported 个';

  @override
  String supportedToolsMissing(Object? missingCount) =>
      '还有 $missingCount 个支持的工具没在这台电脑上找到';

  @override
  String get syncComplete => '已完成同步';

  @override
  String syncCompleted(
    Object? files,
    Object? reused,
    Object? inserted,
    Object? updated,
    Object? seconds,
  ) =>
      '同步完成：扫描 $files 个文件，$reused新增 $inserted 条，有变化的 $updated 条，用时 $seconds 秒。';

  @override
  String syncFailed0(Object? error) => '同步失败：$error';

  @override
  String get syncFailedPreviouslyCollectedDataIsStill => '同步失败，已保留先前采集的数据。';

  @override
  String syncFinishedWithWarnings(Object? warning) => '同步完成，有异常警告：$warning';

  @override
  String get syncNow => '立即同步';

  @override
  String get syncUsage => '同步用量';

  @override
  String syncedHoursAgo(Object? hours) => '$hours 小时前完成';

  @override
  String syncedMinutesAgo(Object? minutes) => '$minutes 分钟前完成';

  @override
  String synced0NoIssues(Object? value) => '$value同步过，一切正常';

  @override
  String syncedDaysAgo(Object? days) => '$days 天前完成';

  @override
  String get syncedJustNow => '刚刚完成同步';

  @override
  String get syncing => '正在同步…';

  @override
  String get syncing2 => '同步中…';

  @override
  String get syncing3 => '正在同步';

  @override
  String tableSpanningSessions(
    Object? tokens,
    Object? spanUnit,
    Object? bucketUnit,
  ) => '另有 $tokens token 来自跨$spanUnit的会话快照，没法按$bucketUnit拆开，不在这张表里；上面的用量已经算上了。';

  @override
  String get technicalDetails => '技术细节';

  @override
  String get technicalNotes => '口径原文';

  @override
  String thisHourSoFar(Object? hour, Object? comparison) =>
      '$hour:00 到现在$comparison';

  @override
  String builtInVersion(Object? value) => '$value · 内置';

  @override
  String toolDidNotLogGenerationTime(Object? tool) => '$tool 的日志里没记生成时长。';

  @override
  String toolDidNotLogFirstTokenTime(Object? tool) => '$tool 的日志里没记首字时间。';

  @override
  String lastSyncReadFailures(Object? failures) =>
      '上次同步有 $failures 处没读成功，其余已经更新';

  @override
  String filteredPeriod(Object? value) => '$value筛选后';

  @override
  String fractionalHours(Object? value) => '$value 小时';

  @override
  String hoursAgo(Object? hours) => '$hours 小时前';

  @override
  String updateAvailable(Object? latest) => '$latest 可以更新了';

  @override
  String onlyVersionSoFar(Object? current) => '$current 是目前唯一的版本';

  @override
  String upToDate(Object? current) => '$current 已是最新';

  @override
  String sourceStatusWithLastRefresh(Object? status, Object? lastSuccess) =>
      '$status · 上次成功 $lastSuccess';

  @override
  String averageSpeedIncludesWait(Object? tool) =>
      '$tool 只记了整次请求的时长，这是算上等待的平均速度。';

  @override
  String roundedMinutes(Object? value) => '$value 分';

  @override
  String minutesAgo(Object? minutes) => '$minutes 分钟前';

  @override
  String additionalNewsSources(Object? count) => '另有 $count 个来源';

  @override
  String cacheInputShare(Object? value) => '$value 的输入走了缓存';

  @override
  String shareOfTotal(Object? value) => '占 $value';

  @override
  String sessionTotalsOnlyForTool(Object? name) =>
      '$name 只记录每个会话的总数，算在开始那天，没有每次请求的时间，无法按天拆分。';

  @override
  String peakHoursInTimeZone(Object? value) => '$value，以下时段为高峰，结束时刻不含在内：';

  @override
  String sourceMonthlyTokens(Object? tokens) => '本月 $tokens token · ';

  @override
  String partiallyUnreadSuffix(Object? unread) => '，$unread 条未读';

  @override
  String get chineseNumberUnits => '万 / 亿';

  @override
  String get chineseNumberExample => '18.2亿 token · 3700万 token';

  @override
  String get englishNumberExample => '1.82B token · 37.0M token';

  @override
  String get theAppWillTryAgainTomorrowYou => '明天会再试，也可以现在重试。';

  @override
  String get theClientDidNotReportThisField => '客户端没有上报该字段';

  @override
  String get theEarliestRecord => '最早一条记录';

  @override
  String theFirstRecordIsFrom0Older(Object? firstSeenText) =>
      '最早的一条记录在 $firstSeenText。更早的用量，工具已经没有保留日志，所以统计不到。以后每次打开都会自动补上新的用量。';

  @override
  String get theLastSyncDidNotFinish => '上次同步没有完成。';

  @override
  String get lastSyncIncomplete => '上次同步没有完成';

  @override
  String get recentSyncIncomplete => '最近的同步未完成';

  @override
  String get theLocalCacheIsUnavailableTryRefreshing => '本地缓存暂不可用，可尝试刷新。';

  @override
  String get theLogDidNotRecordThisField => '日志里没记这一项。';

  @override
  String get theLogHasNoSessionIdFor => '这次请求的日志里没有会话编号，打不开所在的会话。';

  @override
  String get theResponseExceededTheSizeLimitCached => '来源响应超过大小上限，本次未更新缓存。';

  @override
  String get theSameTimeYesterday => '昨天同一时间';

  @override
  String get theSourceDidNotProvideAPublication => '来源未提供发布时间';

  @override
  String get theSourceIsRateLimitingRequestsIt => '来源暂时限制请求，下一轮自动刷新会跳过它。';

  @override
  String get theSourceIsUnavailableTryAgainShortly => '来源暂时无法响应，请稍后重试。';

  @override
  String get theSourceReturnedAnUnsupportedFormatCached =>
      '来源返回了不支持的内容类型，本次未更新缓存。';

  @override
  String get theSourceTimedOutTryAgainShortly => '连接来源超时，请稍后重试。';

  @override
  String get theToolDidNotLogThis => '工具没有写进日志';

  @override
  String get theWaitTimedOutSyncMayStill => '等待超时，同步可能仍在进行';

  @override
  String themeShortcut(Object? value) => '$value；长按跟随系统';

  @override
  String get thereAreNoPricesForTheModels => '这段时间用到的模型都还没有价格';

  @override
  String theseResultsUse0PopularityScoresUse(Object? units) =>
      '当前结果包含 $units，不同热度单位无法比较。';

  @override
  String get thisCodexRequestBeganWithATool =>
      'Codex 这次请求直接从工具调用开始，日志里看不到第一段输出的时间。';

  @override
  String get thisHour => '这一小时';

  @override
  String get thisMonth => '这个月';

  @override
  String get thisMonth2 => '本月';

  @override
  String get thisRequestDidNotFinishNormallySo => '这次请求没有正常结束，不算速度。';

  @override
  String get thisSessionMayNoLongerBeIn => '这条会话可能已不在账本中。';

  @override
  String get thisToolLogsOneTotalPerSession => '（这个工具每个会话只写一条总数）';

  @override
  String get thisToolLogsTimingForAWhole => '这个工具按一整轮对话记录时间，一轮里可能有多次请求。';

  @override
  String get thisToolLogsTimingForAWhole2 =>
      '这个工具只按一整轮对话记录时间，一轮里可能有多次请求，不能和其他工具的‘每次请求’直接比。';

  @override
  String get thisWeek => '这周';

  @override
  String get thisWeek2 => '本周';

  @override
  String get thisYearSTotal => '这一年一共';

  @override
  String get thu2 => '周四';

  @override
  String get tier => '档位';

  @override
  String get time => '时间';

  @override
  String get timeFromSendingTheRequestToThe =>
      '从发出请求到看到第一段输出（含思考）的时间。‘一般’是一半请求不超过这个时间，‘慢时’是九成请求不超过这个时间。';

  @override
  String get timeOutsideExpectedRange => '时间不在合理范围';

  @override
  String get timeUnavailable => '时间不可用';

  @override
  String get timedOnly => '只看有计时的';

  @override
  String get timedOut => '超时';

  @override
  String timedRequestCoverage(Object? requests, Object? recorded) =>
      '$requests 次请求里 $recorded 次有记录';

  @override
  String moreTimingEstimates(int count) => '· 另有 $count 种估算';

  @override
  String get timingReportedByTheClient => '客户端记录的计时';

  @override
  String get to => '结束';

  @override
  String get today => '今天';

  @override
  String today0(Object? base) => '今天 · $base';

  @override
  String get tokenBreakdown => 'token 构成';

  @override
  String get tokenLensOnlyReadsLogFilesCheck =>
      'Token Lens 只读取日志，不会修改。请检查这个文件夹的读取权限，然后点「立即同步」。';

  @override
  String get tokenLensReadsAiCodingToolLogs =>
      'Token Lens 读取 AI 编程工具的日志。去「工具」页看看找到了哪些工具，或者立即同步。';

  @override
  String get tokenLensSyncsOnceEachTimeIt => '每次打开 Token Lens 会自动同步一次，也可以手动同步。';

  @override
  String get tokensCountTowardUsageTheirCostIs => '这些用量照常统计 token，但不计入金额';

  @override
  String get tokensGeneratedPerSecondAfterOutputBegins =>
      '模型开始输出后，每秒生成的 token 数。';

  @override
  String get tokenUnit => 'token';

  @override
  String get tool => '工具';

  @override
  String get toolSources => '工具';

  @override
  String get toolUpdates => '工具更新';

  @override
  String get tools => '工具';

  @override
  String toolsFound(Object? count) => '在这台电脑上找到 $count 个工具';

  @override
  String toolsFoundOnComputer(Object? count) => '这台电脑上找到 $count 个 AI 编程工具。';

  @override
  String get toolsInThisPeriod => '本期工具';

  @override
  String get toolsThatLogOnlySessionTotalsHave => '只记录会话总数的工具没有逐次请求，不出现在这里。';

  @override
  String topFiveModels(Object? value) => '$value用得最多的 5 个';

  @override
  String get topModels => '常用模型';

  @override
  String get total => '累计';

  @override
  String total0(Object? value) => '累计 $value';

  @override
  String total01(Object? value1, Object? value2) => '累计 $value1 · $value2';

  @override
  String get totalEstCost => '累计约值';

  @override
  String get totalRequests => '累计请求';

  @override
  String get totalSoFar => '到现在一共';

  @override
  String get totalUsage => '累计用量';

  @override
  String get trend => '趋势';

  @override
  String trendAxisLabels(Object? labels) => '趋势纵轴：$labels';

  @override
  String get trendChartFocusItAndUseThe => '趋势图：聚焦后用左右方向键逐个查看时段';

  @override
  String get trendChartFocusItAndUseThe2 => '趋势图：聚焦后用左右方向键逐个查看时段，回车看这个时段的明细';

  @override
  String trendWithAverageHint(Object? unit, Object? actionHint) =>
      '每$unit用了多少，颜色代表工具，虚线是平均值$actionHint';

  @override
  String trendingItemLabel(
    Object? rank,
    Object? title,
    Object? score,
    Object? unit,
  ) => '热点第 $rank 名：$title，$score $unit';

  @override
  String get trendingNow => '当前热点';

  @override
  String get trendingSources => '热点来源';

  @override
  String get tryAnotherCategorySourceTypeOrSearch => '试试其他分类、来源、类型或关键词。';

  @override
  String get tryAnotherFilter => '换个筛选看看。';

  @override
  String get tue2 => '周二';

  @override
  String get type => '类型';

  @override
  String typicalAndSlowTiming(Object? typical, Object? slow) =>
      '一般 $typical 秒，慢时 $slow 秒';

  @override
  String unchangedFiles(Object? reused) => '其中 $reused 个没变（沿用上次结果），';

  @override
  String get unknownModel => '未知模型';

  @override
  String get unknownTime => '时间未知';

  @override
  String get unknownTimingSource => '计时来源未知';

  @override
  String get unmarked => '未标记';

  @override
  String get unpriced => '未定价';

  @override
  String get unpricedBecauseTheModelIsMissing => '没有模型名、不计价';

  @override
  String unreachableUpdateCheck(Object? checked, Object? retry) =>
      '连不上 GitHub · $checked。$retry';

  @override
  String get unread => '未读';

  @override
  String unread0(Object? unread) => '未读 $unread';

  @override
  String unreadCount(Object? count) => '$count 条未读';

  @override
  String get unstar => '取消收藏';

  @override
  String get unsupportedFormat => '类型不符';

  @override
  String get upcoming => ' · 还没到';

  @override
  String get upcoming2 => '还没到';

  @override
  String updateAvailableDetails(Object? released, Object? version) =>
      '$released你现在用的是 $version';

  @override
  String get updateCheckFailed => '没检查成功';

  @override
  String get updateRate => '更新汇率';

  @override
  String get updates => '更新';

  @override
  String get updating => '更新中…';

  @override
  String get upvotes => '赞';

  @override
  String get usage => '用量';

  @override
  String get usageAppearsHereAfterTheToolWrites =>
      'Token Lens 只统计已经写进日志的用量。可以换个时间范围，或者在工具里用一会儿再回来。';

  @override
  String get usageBreakdown => '用量明细';

  @override
  String get usageByTool => '按工具分布';

  @override
  String get usageIsCountedWhenEachRecordOccurred =>
      '时段用量按记录发生时间归属；只记录总数的会话算在开始那天，不记录请求数。';

  @override
  String get usageIsReady => '统计好了';

  @override
  String get usageOverview => '用量总览';

  @override
  String get usageReflectsTheFiltersSessionTotalsCover =>
      '筛选后的用量，累计是整个会话的总数，不受筛选影响。';

  @override
  String usageTrendHint(Object? unit, Object? actionHint) =>
      '每$unit用了多少，颜色代表工具$actionHint';

  @override
  String get usd => '美元 \$';

  @override
  String get usdMillionTokensADashMeansNo => 'USD / 百万 token · — 表示不单独计价';

  @override
  String get useASupportedAiCodingToolThen => '用过支持的 AI 编程工具以后，点「立即同步」。';

  @override
  String get verifiedAgainstTheProviderSPricingPage => '和厂商的价格页逐项对过';

  @override
  String get verifiedWithRealLogs => '用真实日志核对过';

  @override
  String get version => '版本';

  @override
  String get view => '范围';

  @override
  String view0InBreakdown(Object? value) => '在明细里看 $value';

  @override
  String get view2 => '视图';

  @override
  String get viewAll => '看全部';

  @override
  String get viewAllSessions => '查看全部会话';

  @override
  String get viewBreakdown => '看明细';

  @override
  String get viewDetails => '查看详情';

  @override
  String viewSession01(Object? session, Object? tool) => '查看会话：$session，$tool';

  @override
  String get viewThisMonth => '看本月';

  @override
  String get viewToolSources => '查看工具';

  @override
  String get viewUpdateDetails => '点开看怎么更新';

  @override
  String get viewUsage => '去看看';

  @override
  String get sourceViewUsage => '看用量';

  @override
  String vs0(Object? comparison) => '比$comparison';

  @override
  String get vsThisTimeYesterday => '，比昨天这时候';

  @override
  String get wed2 => '周三';

  @override
  String get weightedByTime => '区间加权';

  @override
  String get welcomeToTokenLens => '欢迎使用 Token Lens';

  @override
  String get whenRepeatedContextHitsTheCacheIt =>
      '工具重复发送的上下文命中缓存时，按缓存价而不是输入价计费。这里是两者的差额，按公开价估算。';

  @override
  String get whereTheTokensWent => 'token 是怎么构成的';

  @override
  String get withUsageInThisPeriod => '这段时间里有用量的';

  @override
  String get workingDirectory => '工作目录';

  @override
  String yearActiveDaysAndStreakTail(int activeDays, int streak) =>
      ' 天，最长连续 $streak 天';

  @override
  String yearActiveDaysTail(int activeDays) => ' 天';

  @override
  String get yearActivityLead => '过去一年活跃 ';

  @override
  String yearNewcomerLead(String date) => '从 $date开始记录，已经活跃 ';

  @override
  String get yesterday => '昨天';

  @override
  String yesterday0(Object? base) => '昨天 · $base';

  @override
  String get youCanRetryNow => '可以现在重试。';

  @override
  String currentVersion(Object? current) => '你现在用的是 $current';
}
