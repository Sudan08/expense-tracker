import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/stale_async_notifier.dart';
import '../../data/transactions_repository.dart';
import '../../models/monthly_spend.dart';

/// The primary ledger currency. Hardcoded rather than inferred, matching
/// core/money.dart's own default -- the dashboard's headline totals and
/// category bars are for this currency only. See MonthlySpend's doc comment
/// for why other currencies are never folded into it.
const primaryCurrency = 'NPR';

/// The month currently shown on the dashboard.
final selectedMonthProvider = StateProvider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month);
});

/// True once selectedMonthProvider is already at the current calendar month
/// -- used to disable the "next month" control rather than let it navigate
/// into a month with no data and no way to tell that apart from "not synced
/// yet".
final isCurrentMonthProvider = Provider<bool>((ref) {
  final month = ref.watch(selectedMonthProvider);
  final now = DateTime.now();
  return month.year == now.year && month.month == now.month;
});

/// Hides the Spent figure behind that card's own eye icon. Received has its
/// own independent toggle below, so either can be revealed without the
/// other.
///
/// Defaults to **hidden**, reset every cold start (deliberately not
/// persisted -- "hidden by default" should mean exactly that on every
/// launch, not just the first one) -- a glance at the phone shouldn't show a
/// bank total to whoever's looking over your shoulder. The category
/// breakdown and heatmap below are unmasked either way, since that's a
/// separate, coarser view of the same money and masking it too would cost
/// the dashboard's whole point of being glanceable.
final spentHiddenProvider = StateProvider<bool>((ref) => true);

/// See spentHiddenProvider -- the Received card's own, independent toggle.
final receivedHiddenProvider = StateProvider<bool>((ref) => true);

/// Per-month cache for _MonthlySpendNotifier.
///
/// Riverpod's normal rebuild-on-dependency-change (this notifier's build()
/// watches selectedMonthProvider) reruns build() from scratch whenever the
/// month changes, and the state that produces has no memory of "this exact
/// value was already fetched two taps ago" -- from the framework's point of
/// view, flipping to September and flipping *back* to August look identical
/// to visiting August for the very first time. AsyncValueView shows its
/// loading branch whenever `!state.hasValue`, so every single month change
/// paid for a full-screen spinner, even to revisit a month already on
/// screen thirty seconds earlier. This is what tells those two cases apart.
class _MonthKey {
  const _MonthKey(this.year, this.month);
  factory _MonthKey.of(DateTime m) => _MonthKey(m.year, m.month);
  final int year;
  final int month;

  @override
  bool operator ==(Object other) => other is _MonthKey && other.year == year && other.month == month;
  @override
  int get hashCode => Object.hash(year, month);
}

class _MonthlySpendNotifier extends StaleAsyncNotifier<List<MonthlySpend>> {
  // Data changes at most once a day (the worker's daily batch run), so this
  // is generous -- ensureFresh() firing on every app resume would otherwise
  // refetch far more often than the underlying data could possibly change.
  @override
  Duration get staleTime => const Duration(minutes: 5);

  @override
  Future<List<MonthlySpend>> fetch() {
    final month = ref.read(selectedMonthProvider);
    return ref.read(dashboardRepositoryProvider).monthlySpend(month);
  }

  // Instance fields on a Notifier survive every rebuild triggered by a
  // watched dependency changing (the month), and are wiped only when the
  // provider itself is invalidated -- which is exactly the lifetime this
  // cache wants, and exactly why every write path that can change a
  // transaction's month (recategorize, manual entry, gap fill) calls
  // `ref.invalidate(monthlySpendProvider)` rather than this notifier's own
  // refresh(): invalidate recreates the notifier and starts this map empty
  // again, which is the only safe response to a write that could belong to
  // any month, not just the one currently on screen.
  final Map<_MonthKey, List<MonthlySpend>> _cache = {};
  final Map<_MonthKey, DateTime> _cachedAt = {};

  bool _isStale(_MonthKey key) {
    final at = _cachedAt[key];
    return at == null || DateTime.now().difference(at) > staleTime;
  }

  @override
  FutureOr<List<MonthlySpend>> build() {
    // Watched (not read): changing the month -- via the chevrons or the
    // swipe gesture -- must still react through Riverpod's own dependency
    // graph. What changed is what happens next: a month never seen before
    // fetches and waits: a month already cached returns synchronously
    // (state.hasValue is true from the first frame, no spinner), and gets a
    // quiet background refetch only if its cached copy has gone stale.
    final month = ref.watch(selectedMonthProvider);
    final key = _MonthKey.of(month);

    final cached = _cache[key];
    if (cached == null) {
      return fetch().then((value) {
        _cache[key] = value;
        _cachedAt[key] = DateTime.now();
        return value;
      });
    }

    if (_isStale(key)) {
      fetch().then((fresh) {
        _cache[key] = fresh;
        _cachedAt[key] = DateTime.now();
        // Only swap the visible state in if the user hasn't since flipped
        // to a different month -- otherwise this would overwrite whatever
        // they're looking at now with a late response about one they left.
        if (_MonthKey.of(ref.read(selectedMonthProvider)) == key) {
          state = AsyncData(fresh);
        }
      });
    }
    return cached;
  }

  /// Pull-to-refresh: bypass staleness and hit the network for the month
  /// currently on screen regardless of how fresh its cache is -- a manual
  /// pull is an explicit "check now," same rule StaleAsyncNotifier states
  /// for every other provider in the app.
  @override
  Future<void> refresh() async {
    final key = _MonthKey.of(ref.read(selectedMonthProvider));
    state = AsyncLoading<List<MonthlySpend>>().copyWithPrevious(state);
    final result = await AsyncValue.guard(fetch);
    if (result case AsyncData(:final value)) {
      _cache[key] = value;
      _cachedAt[key] = DateTime.now();
    }
    state = result.hasError ? result.copyWithPrevious(state) : result;
  }

  /// App-resume check: refetch the month on screen only if its own cached
  /// copy is stale, rather than the base class's single-value staleness
  /// (which this notifier's per-month cache has no use for, since it never
  /// calls super.build()).
  @override
  Future<void> ensureFresh() async {
    if (_isStale(_MonthKey.of(ref.read(selectedMonthProvider)))) await refresh();
  }
}

final monthlySpendProvider = AsyncNotifierProvider<_MonthlySpendNotifier, List<MonthlySpend>>(
  _MonthlySpendNotifier.new,
);

/// monthlySpendProvider rows restricted to primaryCurrency -- what the
/// category bars and headline totals are built from.
final primaryCurrencySpendProvider = Provider<AsyncValue<List<MonthlySpend>>>((ref) {
  final spend = ref.watch(monthlySpendProvider);
  return spend.whenData((rows) => rows.where((r) => r.currency == primaryCurrency).toList());
});

/// Rows in any other currency, for the "you also spent X in USD" note.
/// Never summed into MonthTotals -- see MonthlySpend's doc comment on why.
final foreignCurrencySpendProvider = Provider<AsyncValue<List<MonthlySpend>>>((ref) {
  final spend = ref.watch(monthlySpendProvider);
  return spend.whenData((rows) => rows.where((r) => r.currency != primaryCurrency).toList());
});

class MonthTotals {
  final int spentPaisa;
  final int receivedPaisa;
  MonthTotals(this.spentPaisa, this.receivedPaisa);
}

final monthTotalsProvider = Provider<AsyncValue<MonthTotals>>((ref) {
  final spend = ref.watch(primaryCurrencySpendProvider);
  return spend.whenData((rows) {
    var spent = 0;
    var received = 0;
    for (final r in rows) {
      spent += r.spentPaisa;
      received += r.receivedPaisa;
    }
    return MonthTotals(spent, received);
  });
});
