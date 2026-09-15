import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/transactions_repository.dart';
import '../../models/enums.dart';
import '../../models/transaction.dart';
import 'transaction_filter.dart';

/// How many rows one page pulls. Big enough that the common case is one
/// request, small enough that a filter change feels instant.
const _pageSize = 50;

class FilteredTransactions {
  const FilteredTransactions({
    required this.rows,
    required this.hasMore,
    required this.loadingMore,
  });

  final List<Txn> rows;

  /// Whether the last page came back full. A short page means the end --
  /// there is no count query, deliberately: PostgREST's exact count is a
  /// second scan of the same predicate, and "is there more" is the only
  /// question the UI actually asks.
  final bool hasMore;
  final bool loadingMore;

  FilteredTransactions copyWith({List<Txn>? rows, bool? hasMore, bool? loadingMore}) =>
      FilteredTransactions(
        rows: rows ?? this.rows,
        hasMore: hasMore ?? this.hasMore,
        loadingMore: loadingMore ?? this.loadingMore,
      );

  /// Totals over what is *loaded*, not over the whole matching set.
  /// Transfers are left out of both: money moving between your own accounts
  /// nets to zero and would inflate each side (plan invariant 7).
  int get outPaisa => rows
      .where((t) => !t.isTransfer && t.direction == Direction.debit)
      .fold(0, (sum, t) => sum + t.amountPaisa);

  int get inPaisa => rows
      .where((t) => !t.isTransfer && t.direction == Direction.credit)
      .fold(0, (sum, t) => sum + t.amountPaisa);
}

/// The filtered, paged transaction list.
///
/// Rebuilds from scratch whenever the filter changes (it is watched), which
/// is correct here in a way it wasn't for monthlySpendProvider: a filter
/// change genuinely is a different question, there is no bounded set of
/// filters worth caching, and the answer must not be a stale list that
/// silently disagrees with the chips above it.
class FilteredTransactionsNotifier extends AsyncNotifier<FilteredTransactions> {
  TransactionFilter _filter = const TransactionFilter();
  DateTime? _fetchedAt;

  /// Mirrors StaleAsyncNotifier's contract for the one caller that needs it
  /// (app resume). Not extending that class: its cache model is a single
  /// value refetched whole, where this one appends pages and must not throw
  /// them away just because the first page went stale.
  static const staleTime = Duration(minutes: 3);

  @override
  Future<FilteredTransactions> build() async {
    _filter = ref.watch(transactionFilterProvider);
    final rows = await ref
        .read(transactionsRepositoryProvider)
        .fetchFiltered(_filter, offset: 0, limit: _pageSize);
    _fetchedAt = DateTime.now();
    return FilteredTransactions(
      rows: rows,
      hasMore: rows.length == _pageSize,
      loadingMore: false,
    );
  }

  Future<void> ensureFresh() async {
    final at = _fetchedAt;
    if (at == null || DateTime.now().difference(at) > staleTime) await refresh();
  }

  /// Append the next page. A no-op while one is already in flight or the
  /// end has been reached, so the scroll listener can call it freely on
  /// every frame near the bottom without queueing duplicate requests.
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || !current.hasMore || current.loadingMore) return;

    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final next = await ref.read(transactionsRepositoryProvider).fetchFiltered(
            _filter,
            offset: current.rows.length,
            limit: _pageSize,
          );
      // The filter may have changed while this page was in flight, in which
      // case build() has already replaced the state with a fresh first page
      // and appending to the old list would splice two different queries
      // together.
      if (ref.read(transactionFilterProvider) != _filter) return;
      state = AsyncData(FilteredTransactions(
        rows: [...current.rows, ...next],
        hasMore: next.length == _pageSize,
        loadingMore: false,
      ));
    } catch (_) {
      // Keep what's already loaded and let the user retry by scrolling
      // again -- dropping a screen of rows because page 4 failed would be
      // a worse answer than a list that stopped growing.
      state = AsyncData(current.copyWith(loadingMore: false));
    }
  }

  /// Re-reads the first page, dropping any extra pages that were scrolled
  /// in. copyWithPrevious keeps the old rows on screen for the round trip,
  /// so a pull-to-refresh never blanks the list.
  Future<void> refresh() async {
    state = AsyncLoading<FilteredTransactions>().copyWithPrevious(state);
    state = await AsyncValue.guard(build);
    _fetchedAt = DateTime.now();
  }
}

final filteredTransactionsProvider =
    AsyncNotifierProvider<FilteredTransactionsNotifier, FilteredTransactions>(
  FilteredTransactionsNotifier.new,
);

/// One day's worth of the loaded list, in display order.
class TxnDaySection {
  const TxnDaySection({required this.day, required this.rows});
  final DateTime day;
  final List<Txn> rows;

  int get netPaisa => rows
      .where((t) => !t.isTransfer)
      .fold(0, (sum, t) => sum + (t.direction == Direction.credit ? t.amountPaisa : -t.amountPaisa));
}

/// Groups the loaded rows into calendar days.
///
/// This is the single biggest legibility change to the list: an unbroken
/// run of rows makes the reader do the date arithmetic themselves on every
/// line, where a day header states it once and lets proximity do the work.
///
/// Kathmandu calendar days, matching every other date boundary in the app
/// (plan invariant 2). NPT is a fixed UTC+5:45 with no DST, so this is
/// arithmetic rather than a timezone lookup.
final transactionDaySectionsProvider = Provider<List<TxnDaySection>>((ref) {
  final rows = ref.watch(filteredTransactionsProvider).valueOrNull?.rows ?? const <Txn>[];
  const kathmandu = Duration(hours: 5, minutes: 45);

  final sections = <TxnDaySection>[];
  DateTime? currentDay;
  var bucket = <Txn>[];

  for (final txn in rows) {
    final local = txn.occurredAt.toUtc().add(kathmandu);
    final day = DateTime(local.year, local.month, local.day);
    if (currentDay == null || day != currentDay) {
      if (currentDay != null) sections.add(TxnDaySection(day: currentDay, rows: bucket));
      currentDay = day;
      bucket = [];
    }
    bucket.add(txn);
  }
  if (currentDay != null) sections.add(TxnDaySection(day: currentDay, rows: bucket));
  return sections;
});
