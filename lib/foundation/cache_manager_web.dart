class CacheManager {
  static CacheManager? instance;

  int get currentSize => 0;

  void setLimitSize(int size) {}

  Future<void> writeCache(
    String key,
    List<int> data, [
    int duration = 7 * 24 * 60 * 60 * 1000,
  ]) async {}

  Future<dynamic> findCache(String key) async => null;

  void checkCacheIfRequired() {}

  Future<void> checkCache() async {}

  Future<void> delete(String key) async {}

  Future<void> clear() async {}
}
