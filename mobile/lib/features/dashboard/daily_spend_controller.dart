import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/stale_async_notifier.dart';
import '../../data/data_health_repository.dart';
import '../../data/transactions_repository.dart';
import '../../models/daily_spend.dart';
import 'dashboard_controller.dart';

/// 53 weeks -- one full GitHub-style grid, scrollable to the oldest column.
const heatmapWindowDays = 371;

const _kathmanduOffset = Duration(hours: 5, minutes: 45);

DateTime _kathmanduDate(DateTime utc) {
  final k = utc.toUtc().add(_kathmanduOffset);
  return DateTime(k.year, k.month, k.day);
}

String _dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class _DailySpendNotifier extends StaleAsyncNotifier<List<DailySpend>> {
  @override
  Duration get staleTime => const Duration(minutes: 5);

  @override
  Future<List<DailySpend>> fetch() async {
    final repo = ref.read(dashboardRepositoryProvider);
    final today = DateTime.now();
    final from = today.subtract(const Duration(days: heatmapWindowDays - 1));
    final rows = await repo.dailySpend(from, today);
    return rows.where((r) => r.currency == primaryCurrency).toList();
  }
}

final dailySpendProvider = AsyncNotifierProvider<_DailySpendNotifier, List<DailySpend>>(
  _DailySpendNotifier.new,
);

class _EarliestTransactionNotifier extends StaleAsyncNotifier<DateTime?> {
  // This can only move if older data gets backfilled, which never happens
  // in the normal daily-sync flow -- long stale time.
  @override
  Duration get staleTime => const Duration(hours: 1);

  @override
  Future<DateTime?> fetch() => ref.read(transactionsRepositoryProvider).earliestTransactionAt();
}

final earliestTransactionAtProvider =
    AsyncNotifierProvider<_EarliestTransactionNotifier, DateTime?>(
  _EarliestTransactionNotifier.new,
);

enum HeatmapDayKind {
  /// Before the earliest transaction this account has ever seen -- there is
  /// no claim being made about this day at all, not even "nothing spent".
  beforeData,

  /// Falls strictly between two known transactions on an unresolved
  /// ledger_gaps row -- money moved and the pipeline never saw why. Must
  /// never render the same as a genuine zero-spend day.
  uncertainGap,

  /// A day the pipeline actually covers. spentPaisa is a real total, zero
  /// included.
  spend,
}

class HeatmapDay {
  final DateTime day;
  final HeatmapDayKind kind;
  final int spentPaisa;

  /// 0 = no spend, 1..4 = quartile of this day's spend among all non-zero
  /// spend days in the fetched window. Meaningless (0) outside kind == spend.
  final int bucket;

  HeatmapDay({required this.day, required this.kind, required this.spentPaisa, required this.bucket});
}

/// Combines three already-fetched providers into the heatmap's day list --
/// no network call of its own. openLedgerGapsProvider is the same provider
/// the Data Health screen reads; watching it here doesn't refetch it, it
/// reuses whatever's cached (or triggers exactly one fetch the first time
/// anything asks for it).
final heatmapDaysProvider = Provider<AsyncValue<List<HeatmapDay>>>((ref) {
  final dailyAsync = ref.watch(dailySpendProvider);
  final earliestAsync = ref.watch(earliestTransactionAtProvider);
  final gapsAsync = ref.watch(openLedgerGapsProvider);

  if (dailyAsync.hasError) {
    return AsyncValue.error(dailyAsync.error!, dailyAsync.stackTrace ?? StackTrace.current);
  }
  if (earliestAsync.hasError) {
    return AsyncValue.error(earliestAsync.error!, earliestAsync.stackTrace ?? StackTrace.current);
  }
  if (gapsAsync.hasError) {
    return AsyncValue.error(gapsAsync.error!, gapsAsync.stackTrace ?? StackTrace.current);
  }
  if (!dailyAsync.hasValue || !earliestAsync.hasValue || !gapsAsync.hasValue) {
    return const AsyncValue.loading();
  }

  final byDate = {for (final d in dailyAsync.value!) _dateKey(d.day): d};
  final earliest = earliestAsync.value == null ? null : _kathmanduDate(earliestAsync.value!);

  // Both timestamps are non-null now: v_open_ledger_gaps inner-joins the two
  // bracketing transactions, so a gap only reaches here if both still exist
  // (migration 20260913000000).
  final gapWindows = <(DateTime, DateTime)>[
    for (final g in gapsAsync.value!)
      (_kathmanduDate(g.afterOccurredAt), _kathmanduDate(g.beforeOccurredAt)),
  ];

  bool inAnyGap(DateTime day) => gapWindows.any((w) => day.isAfter(w.$1) && day.isBefore(w.$2));

  final today = _kathmanduDate(DateTime.now().toUtc());
  final start = today.subtract(const Duration(days: heatmapWindowDays - 1));

  // Quartile thresholds over non-zero spend days only -- see
  // docs/APP_IMPROVEMENTS.md section 3.1(a) on why this must be quantile,
  // not a linear scale: personal spend is heavy-tailed enough that a linear
  // scale renders one black square and the rest of the year invisible.
  final nonZero = dailyAsync.value!.map((d) => d.spentPaisa).where((p) => p > 0).toList()..sort();
  int bucketFor(int amount) {
    if (amount <= 0 || nonZero.isEmpty) return 0;
    final q1 = nonZero[(nonZero.length * 0.25).floor().clamp(0, nonZero.length - 1)];
    final q2 = nonZero[(nonZero.length * 0.50).floor().clamp(0, nonZero.length - 1)];
    final q3 = nonZero[(nonZero.length * 0.75).floor().clamp(0, nonZero.length - 1)];
    if (amount <= q1) return 1;
    if (amount <= q2) return 2;
    if (amount <= q3) return 3;
    return 4;
  }

  final days = <HeatmapDay>[];
  for (var i = 0; i <= heatmapWindowDays - 1; i++) {
    final day = start.add(Duration(days: i));
    if (earliest != null && day.isBefore(earliest)) {
      days.add(HeatmapDay(day: day, kind: HeatmapDayKind.beforeData, spentPaisa: 0, bucket: 0));
      continue;
    }
    if (inAnyGap(day)) {
      days.add(HeatmapDay(day: day, kind: HeatmapDayKind.uncertainGap, spentPaisa: 0, bucket: 0));
      continue;
    }
    final spent = byDate[_dateKey(day)]?.spentPaisa ?? 0;
    days.add(HeatmapDay(day: day, kind: HeatmapDayKind.spend, spentPaisa: spent, bucket: bucketFor(spent)));
  }
  return AsyncValue.data(days);
});
