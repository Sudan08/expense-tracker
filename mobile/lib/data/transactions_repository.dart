import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/supabase/supabase_providers.dart';
import '../models/daily_spend.dart';
import '../models/enums.dart';
import '../models/monthly_spend.dart';
import '../features/transactions/transaction_filter.dart';
import '../models/transaction.dart';
import 'categories_repository.dart';

const _txnSelect = '*, accounts(display_name), categories(name)';

class TransactionsRepository {
  TransactionsRepository(this._client);
  final SupabaseClient _client;

  Future<List<Txn>> fetchRecent({int limit = 100}) async {
    final rows = await _client
        .from('transactions')
        .select(_txnSelect)
        .order('occurred_at', ascending: false)
        .limit(limit);
    return (rows as List).map((r) => Txn.fromRow(r as Map<String, dynamic>)).toList();
  }

  /// One page of the filtered transaction list.
  ///
  /// Every predicate composes in PostgREST with no new SQL, which is the
  /// whole reason docs/APP_IMPROVEMENTS.md section 2.2 sizes this as mostly
  /// Dart. Paged rather than capped: that section is explicit that filters
  /// without paging turn "why is this transaction missing?" into a real
  /// question, since a silent 100-row ceiling is indistinguishable from a
  /// filter that excluded something.
  Future<List<Txn>> fetchFiltered(
    TransactionFilter filter, {
    required int offset,
    required int limit,
  }) async {
    var query = _client.from('transactions').select(_txnSelect);

    final (from, to) = filter.range;
    if (from != null) query = query.gte('occurred_at', from.toUtc().toIso8601String());
    if (to != null) query = query.lt('occurred_at', to.toUtc().toIso8601String());

    if (filter.uncategorizedOnly) {
      query = query.isFilter('category_id', null);
    } else if (filter.categoryIds.isNotEmpty) {
      query = query.inFilter('category_id', filter.categoryIds.toList());
    }
    if (filter.accountIds.isNotEmpty) {
      query = query.inFilter('account_id', filter.accountIds.toList());
    }
    if (filter.direction != null) {
      query = query.eq('direction', directionToDb(filter.direction!));
    }
    if (filter.status != null) {
      query = query.eq('status', txnStatusToDb(filter.status!));
    }
    if (filter.minPaisa != null) query = query.gte('amount_paisa', filter.minPaisa!);
    if (filter.maxPaisa != null) query = query.lte('amount_paisa', filter.maxPaisa!);

    // excluded_from_spend is the honest test for "is this a transfer": a leg
    // the matcher paired carries it, and Txn.isTransfer reads the same field
    // plus transfer_group_id. Filtering on the column keeps the predicate in
    // the database rather than paging rows in only to drop them client-side,
    // which would make the page size lie.
    switch (filter.transfers) {
      case TransferMode.hidden:
        query = query.eq('excluded_from_spend', false);
      case TransferMode.only:
        query = query.eq('excluded_from_spend', true);
      case TransferMode.shown:
        break;
    }

    final search = filter.search.trim();
    if (search.isNotEmpty) {
      // PostgREST's `or` is a comma-separated list wrapped in parens, so a
      // comma or a bracket in the search text would be parsed as structure
      // rather than as text. `%` and `_` are LIKE wildcards and there is no
      // escape for them in a URL filter, so they are dropped rather than
      // backslash-escaped -- a backslash would be sent through literally and
      // match nothing, which is the more confusing failure.
      final safe = search.replaceAll(RegExp(r'[,()%_]'), ' ').trim();
      if (safe.isEmpty) {
        // The whole query was punctuation. Returning everything is a better
        // answer than an `or` clause built from an empty string, which
        // matches every row anyway but looks deliberate in the logs.
        return _mapRows(await query
            .order('occurred_at', ascending: false)
            .order('id', ascending: false)
            .range(offset, offset + limit - 1));
      }
      query = query.or(
        'description_raw.ilike.%$safe%,'
        'counterparty.ilike.%$safe%,'
        'user_note.ilike.%$safe%',
      );
    }

    return _mapRows(await query
        .order('occurred_at', ascending: false)
        // Ties on occurred_at are ordinary -- Nabil reports to the minute --
        // and an unstable sort across pages would drop or duplicate rows at
        // a page boundary. id is arbitrary but total, which is all a
        // tiebreak needs to be.
        .order('id', ascending: false)
        .range(offset, offset + limit - 1));
  }

  static List<Txn> _mapRows(dynamic rows) =>
      (rows as List).map((r) => Txn.fromRow(r as Map<String, dynamic>)).toList();

  Future<List<Txn>> fetchByStatus(TxnStatus status, {int limit = 200}) async {
    final rows = await _client
        .from('transactions')
        .select(_txnSelect)
        .eq('status', txnStatusToDb(status))
        .order('occurred_at', ascending: false)
        .limit(limit);
    return (rows as List).map((r) => Txn.fromRow(r as Map<String, dynamic>)).toList();
  }

  Future<Txn> fetchOne(String id) async {
    final row = await _client.from('transactions').select(_txnSelect).eq('id', id).single();
    return Txn.fromRow(row);
  }

  /// The earliest transaction this user has, by occurred_at. The heatmap
  /// uses this to tell "before any data existed" apart from "covered, but
  /// genuinely nothing spent" -- see docs/APP_IMPROVEMENTS.md section 3.1(b).
  /// A true account_start (plan's worker.account_start) isn't visible from
  /// Supabase at all -- it lives only in the worker's local config.toml --
  /// so this is the closest proxy the phone can compute on its own.
  Future<DateTime?> earliestTransactionAt() async {
    final rows = await _client
        .from('transactions')
        .select('occurred_at')
        .order('occurred_at', ascending: true)
        .limit(1);
    final list = rows as List;
    if (list.isEmpty) return null;
    return DateTime.parse((list.first as Map<String, dynamic>)['occurred_at'] as String);
  }

  /// Every transaction on [day] (a Kathmandu calendar date -- year/month/day
  /// only, time-of-day and any offset on it are ignored). Backs the
  /// heatmap's tap-a-square drill-down.
  ///
  /// Nepal Standard Time is a fixed UTC+5:45 offset with no DST, so the
  /// Kathmandu day boundary translates to a constant UTC range -- no need to
  /// round-trip through a timezone database for this one country.
  Future<List<Txn>> fetchByDate(DateTime day) async {
    const kathmanduOffset = Duration(hours: 5, minutes: 45);
    final startUtc = DateTime.utc(day.year, day.month, day.day).subtract(kathmanduOffset);
    final endUtc = startUtc.add(const Duration(days: 1));
    final rows = await _client
        .from('transactions')
        .select(_txnSelect)
        .gte('occurred_at', startUtc.toIso8601String())
        .lt('occurred_at', endUtc.toIso8601String())
        .order('occurred_at', ascending: false);
    return (rows as List).map((r) => Txn.fromRow(r as Map<String, dynamic>)).toList();
  }

  /// Recategorize from the phone. RLS (section 11.2 of the plan) only grants
  /// column-level update on category_id, category_source, status,
  /// excluded_from_spend, user_note -- an amount/date change would be
  /// rejected by Postgres, not just by this UI.
  ///
  /// [note] is always written, so clearing the field in the sheet clears the
  /// stored note. It lands in user_note, never description_raw: the latter is
  /// the bank's verbatim text and a reparse would overwrite it.
  Future<void> recategorize({
    required String transactionId,
    required String categoryId,
    String? note,
  }) async {
    final trimmed = note?.trim();
    await _client.from('transactions').update({
      'category_id': categoryId,
      'category_source': 'user',
      'status': txnStatusToDb(TxnStatus.categorized),
      'user_note': (trimmed == null || trimmed.isEmpty) ? null : trimmed,
    }).eq('id', transactionId);
  }

  /// Edit just the note, leaving the category and status alone.
  Future<void> updateNote({
    required String transactionId,
    required String? note,
  }) async {
    final trimmed = note?.trim();
    await _client.from('transactions').update({
      'user_note': (trimmed == null || trimmed.isEmpty) ? null : trimmed,
    }).eq('id', transactionId);
  }

  Future<void> confirm(String transactionId) async {
    await _client.from('transactions').update({
      'status': txnStatusToDb(TxnStatus.confirmed),
    }).eq('id', transactionId);
  }

  /// The correction-loop write from plan section 10: recategorizing in the
  /// app teaches the worker's rule engine so the next sync gets it right
  /// without the model. merchant_rules is the one table the phone has
  /// insert on (section 11.2).
  Future<void> learnMerchantRule({
    required String descriptionRaw,
    required String categoryId,
    String? counterpartyLabel,
  }) async {
    final escaped = RegExp.escape(descriptionRaw.trim());
    await _client.from('merchant_rules').insert({
      'user_id': _client.auth.currentUser!.id,
      'pattern': escaped,
      'category_id': categoryId,
      'counterparty_label': counterpartyLabel,
      'learned_from_user': true,
    });
  }
}

final transactionsRepositoryProvider = Provider<TransactionsRepository>((ref) {
  return TransactionsRepository(ref.watch(supabaseClientProvider));
});

class DashboardRepository {
  DashboardRepository(this._client, this._categories);
  final SupabaseClient _client;
  final CategoriesRepository _categories;

  /// v_monthly_spend has no FK PostgREST can use to embed categories(name)
  /// (plan section 9.1 -- it's an aggregate view, category_id is just a
  /// column), so the name join happens here instead of in SQL.
  Future<List<MonthlySpend>> monthlySpend(DateTime month) async {
    // v_monthly_spend.month is `date_trunc('month', occurred_at at time zone
    // 'Asia/Kathmandu')` -- a naive (no-offset) timestamp in Kathmandu wall
    //-clock time. Match that exact shape rather than round-tripping through
    // Dart's DateTime, which would attach the device's own offset.
    final monthKey = '${month.year.toString().padLeft(4, '0')}-'
        '${month.month.toString().padLeft(2, '0')}-01T00:00:00';
    final rows = await _client.from('v_monthly_spend').select().eq('month', monthKey);
    final spend = (rows as List).map((r) => MonthlySpend.fromRow(r as Map<String, dynamic>)).toList();

    final categories = await _categories.fetchAll();
    final byId = {for (final c in categories) c.id: c.name};
    for (final s in spend) {
      s.categoryName = s.categoryId == null ? 'Uncategorized' : byId[s.categoryId];
    }
    return spend;
  }

  /// v_daily_spend rows for [from]..[to] inclusive, both Kathmandu calendar
  /// dates. Backs the heatmap -- see features/dashboard/daily_spend_controller.dart.
  Future<List<DailySpend>> dailySpend(DateTime from, DateTime to) async {
    String dateKey(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final rows = await _client
        .from('v_daily_spend')
        .select()
        .gte('day', dateKey(from))
        .lte('day', dateKey(to));
    return (rows as List).map((r) => DailySpend.fromRow(r as Map<String, dynamic>)).toList();
  }
}

final dashboardRepositoryProvider = Provider<DashboardRepository>((ref) {
  return DashboardRepository(
    ref.watch(supabaseClientProvider),
    ref.watch(categoriesRepositoryProvider),
  );
});
