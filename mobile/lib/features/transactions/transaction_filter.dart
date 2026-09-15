import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/enums.dart';

/// Which slice of time the list covers. Presets rather than two date pickers:
/// "last 3 months" is what you actually want nine times out of ten, and a
/// pair of pickers makes you do arithmetic to get it.
enum DateRangePreset {
  thisMonth,
  lastMonth,
  last3Months,
  thisYear,
  all,
  custom,
}

extension DateRangePresetLabel on DateRangePreset {
  String get label => switch (this) {
        DateRangePreset.thisMonth => 'This month',
        DateRangePreset.lastMonth => 'Last month',
        DateRangePreset.last3Months => 'Last 3 months',
        DateRangePreset.thisYear => 'This year',
        DateRangePreset.all => 'All time',
        DateRangePreset.custom => 'Custom',
      };
}

/// How transfers are treated. Kept separate from every other filter because
/// a transfer isn't a *kind* of spending, it's money that never left your
/// pocket (plan invariant 7) -- so "is it in the list" and "what category is
/// it" are genuinely different questions.
enum TransferMode { shown, hidden, only }

extension TransferModeLabel on TransferMode {
  String get label => switch (this) {
        TransferMode.shown => 'Transfers shown',
        TransferMode.hidden => 'Transfers hidden',
        TransferMode.only => 'Transfers only',
      };
}

/// Everything the transaction list is currently narrowed to.
///
/// One immutable object rather than a scatter of separate providers, for the
/// reason docs/APP_IMPROVEMENTS.md section 2.2 gives: the export feature
/// (section 4) needs to serialise exactly the predicate the user is looking
/// at, and that's free if there is one object to hand it and a nightmare if
/// the predicate is spread across six providers and a widget's local state.
class TransactionFilter {
  const TransactionFilter({
    this.search = '',
    this.preset = DateRangePreset.last3Months,
    this.customFrom,
    this.customTo,
    this.categoryIds = const {},
    this.accountIds = const {},
    this.direction,
    this.status,
    this.transfers = TransferMode.shown,
    this.minPaisa,
    this.maxPaisa,
    this.uncategorizedOnly = false,
  });

  /// Substring match over description_raw, counterparty and user_note.
  final String search;

  final DateRangePreset preset;
  final DateTime? customFrom;
  final DateTime? customTo;

  /// Empty means "any" rather than "none" -- an empty IN () would match
  /// nothing, which is never what an untouched filter should mean.
  final Set<String> categoryIds;
  final Set<String> accountIds;

  final Direction? direction;
  final TxnStatus? status;
  final TransferMode transfers;

  final int? minPaisa;
  final int? maxPaisa;

  /// category_id is null. Deliberately not expressible through [categoryIds]
  /// -- "no category" isn't a category id, and PostgREST's `in` can't carry
  /// a null. It is also the single most useful filter on this screen, since
  /// it is the list of things the pipeline couldn't file.
  final bool uncategorizedOnly;

  static const _defaults = TransactionFilter();

  /// Which of these are actually narrowing anything. Drives the chip row's
  /// active styling and the "N filters" badge, and lets the empty state say
  /// "nothing matches these filters" rather than "no transactions", which
  /// are very different messages.
  int get activeCount {
    var n = 0;
    if (search.trim().isNotEmpty) n++;
    if (preset != _defaults.preset) n++;
    if (categoryIds.isNotEmpty) n++;
    if (accountIds.isNotEmpty) n++;
    if (direction != null) n++;
    if (status != null) n++;
    if (transfers != _defaults.transfers) n++;
    if (minPaisa != null || maxPaisa != null) n++;
    if (uncategorizedOnly) n++;
    return n;
  }

  bool get isDefault => activeCount == 0;

  /// The resolved window, as a half-open [from, to) pair in local time.
  /// Null bounds mean unbounded.
  (DateTime?, DateTime?) get range {
    final now = DateTime.now();
    final thisMonth = DateTime(now.year, now.month);
    return switch (preset) {
      DateRangePreset.thisMonth => (thisMonth, DateTime(now.year, now.month + 1)),
      DateRangePreset.lastMonth => (DateTime(now.year, now.month - 1), thisMonth),
      DateRangePreset.last3Months => (DateTime(now.year, now.month - 2), DateTime(now.year, now.month + 1)),
      DateRangePreset.thisYear => (DateTime(now.year), DateTime(now.year + 1)),
      DateRangePreset.all => (null, null),
      DateRangePreset.custom => (
          customFrom,
          // Inclusive to the user, half-open to the query: picking "to 13
          // Sep" must include everything that happened *on* the 13th.
          customTo == null ? null : DateTime(customTo!.year, customTo!.month, customTo!.day + 1),
        ),
    };
  }

  TransactionFilter copyWith({
    String? search,
    DateRangePreset? preset,
    DateTime? customFrom,
    DateTime? customTo,
    Set<String>? categoryIds,
    Set<String>? accountIds,
    Object? direction = _sentinel,
    Object? status = _sentinel,
    TransferMode? transfers,
    Object? minPaisa = _sentinel,
    Object? maxPaisa = _sentinel,
    bool? uncategorizedOnly,
  }) {
    return TransactionFilter(
      search: search ?? this.search,
      preset: preset ?? this.preset,
      customFrom: customFrom ?? this.customFrom,
      customTo: customTo ?? this.customTo,
      categoryIds: categoryIds ?? this.categoryIds,
      accountIds: accountIds ?? this.accountIds,
      // The nullable fields need a sentinel: `direction ?? this.direction`
      // makes it impossible to ever clear one back to "any".
      direction: direction == _sentinel ? this.direction : direction as Direction?,
      status: status == _sentinel ? this.status : status as TxnStatus?,
      transfers: transfers ?? this.transfers,
      minPaisa: minPaisa == _sentinel ? this.minPaisa : minPaisa as int?,
      maxPaisa: maxPaisa == _sentinel ? this.maxPaisa : maxPaisa as int?,
      uncategorizedOnly: uncategorizedOnly ?? this.uncategorizedOnly,
    );
  }

  static const _sentinel = Object();

  @override
  bool operator ==(Object other) =>
      other is TransactionFilter &&
      other.search == search &&
      other.preset == preset &&
      other.customFrom == customFrom &&
      other.customTo == customTo &&
      _setEq(other.categoryIds, categoryIds) &&
      _setEq(other.accountIds, accountIds) &&
      other.direction == direction &&
      other.status == status &&
      other.transfers == transfers &&
      other.minPaisa == minPaisa &&
      other.maxPaisa == maxPaisa &&
      other.uncategorizedOnly == uncategorizedOnly;

  @override
  int get hashCode => Object.hash(
        search,
        preset,
        customFrom,
        customTo,
        Object.hashAllUnordered(categoryIds),
        Object.hashAllUnordered(accountIds),
        direction,
        status,
        transfers,
        minPaisa,
        maxPaisa,
        uncategorizedOnly,
      );

  static bool _setEq(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}

/// The live filter for the transaction list. A plain StateProvider: the
/// value is immutable and every mutation is a whole-object replacement, so
/// there is no behaviour for a Notifier to hold.
final transactionFilterProvider =
    StateProvider<TransactionFilter>((ref) => const TransactionFilter());
