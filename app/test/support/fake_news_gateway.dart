import 'package:token_lens_app/news_gateway.dart';

const cachedItem = NewsItem(
  id: 'cached',
  title: 'Cached article',
  url: 'https://openai.com/index/cached/',
  description: 'A cached source excerpt.',
);
const freshItem = NewsItem(
  id: 'fresh',
  title: 'Fresh article',
  url: 'https://openai.com/index/fresh/',
);
const cachedNews = NewsSnapshot(
  items: [cachedItem],
  lastSuccessMs: 1700000000000,
);

class FakeNewsGateway implements NewsGateway {
  FakeNewsGateway({this.cached = const NewsSnapshot()});

  NewsSnapshot cached;
  NewsSnapshot? cancelSnapshot;
  Future<NewsSnapshot>? nextRefresh;
  int snapshotCalls = 0;
  int refreshCalls = 0;
  int cancelCalls = 0;
  int shutdownCalls = 0;

  @override
  Future<NewsSnapshot> snapshot() async {
    snapshotCalls++;
    return cached;
  }

  @override
  Future<NewsSnapshot> refresh() {
    refreshCalls++;
    return nextRefresh ?? Future.value(cached);
  }

  @override
  Future<void> cancelRefresh() async {
    cancelCalls++;
    if (cancelSnapshot != null) cached = cancelSnapshot!;
  }

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
  }
}
