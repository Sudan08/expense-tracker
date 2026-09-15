import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Base for every provider that reads from Supabase.
///
/// Plain Riverpod already gives you the cache half for free: a provider
/// that isn't `.autoDispose` holds its last value forever, and every screen
/// that watches it shares that one value instead of each firing its own
/// fetch. What Riverpod has no opinion on is *staleness* -- when a cached
/// value is old enough that it's worth quietly refetching. This class adds
/// that, by hand, in the two places it matters:
///
/// - [ensureFresh] -- call when a screen becomes visible again (app resumed,
///   navigated back to). Refetches only if [staleTime] has elapsed;
///   otherwise it's a no-op and the screen renders the cached value with no
///   network call and no loading state at all.
/// - [refresh] -- call from pull-to-refresh. Always refetches, no matter how
///   fresh the cache is, because a manual pull is an explicit "check now."
///
/// Both paths transition through `AsyncLoading()..copyWithPrevious(state)`
/// rather than a bare `AsyncLoading()`, which keeps `state.hasValue` true
/// and `state.value` pointing at the old data for the whole refetch. Pair
/// this with [AsyncValueView] and a screen never shows a full-screen spinner
/// for anything except its very first, ever, load.
abstract class StaleAsyncNotifier<T> extends AsyncNotifier<T> {
  /// How long a fetched value stays "fresh enough" before [ensureFresh]
  /// will refetch it. Pick this per data source, not one global constant --
  /// categories barely change; a review queue does.
  Duration get staleTime;

  /// The actual network call. Read (never watch) any dependencies here --
  /// this runs outside the notifier's build phase whenever [refresh] fires,
  /// and `ref.watch` is only legal inside [build].
  Future<T> fetch();

  DateTime? _fetchedAt;

  @override
  FutureOr<T> build() async {
    final value = await fetch();
    _fetchedAt = DateTime.now();
    return value;
  }

  bool get isStale =>
      _fetchedAt == null || DateTime.now().difference(_fetchedAt!) > staleTime;

  Future<void> ensureFresh() async {
    if (isStale) await refresh();
  }

  Future<void> refresh() async {
    state = AsyncLoading<T>().copyWithPrevious(state);
    final result = await AsyncValue.guard<T>(fetch);
    _fetchedAt = DateTime.now();
    state = result.hasError ? result.copyWithPrevious(state) : result;
  }
}
