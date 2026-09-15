import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/cache/stale_async_notifier.dart';
import '../core/supabase/supabase_providers.dart';
import '../models/data_health.dart';

/// Everything the pipeline recorded about what went wrong, read-only.
/// All three tables already had "read own" RLS from the initial schema --
/// this is purely new UI over data that was always reachable, never a new
/// grant.
class DataHealthRepository {
  DataHealthRepository(this._client);
  final SupabaseClient _client;

  /// Unresolved balance discontinuities: money moved and no email or SMS
  /// was ever seen for it (plan section 7.3).
  ///
  /// Reads v_open_ledger_gaps rather than ledger_gaps with PostgREST embeds.
  /// The view exists because the gap-fill form needs the bracketing
  /// transactions' balances as well as their timestamps, and because
  /// "only gaps whose transactions both still exist" isn't expressible as
  /// an embed -- see migration 20260913000000.
  Future<List<LedgerGapRow>> fetchOpenGaps() async {
    final rows = await _client
        .from('v_open_ledger_gaps')
        .select()
        .order('detected_at', ascending: false);
    return (rows as List).map((r) => LedgerGapRow.fromRow(r as Map<String, dynamic>)).toList();
  }

  Future<List<FailedEmailRow>> fetchFailedEmails({int limit = 100}) async {
    final rows = await _client
        .from('processed_emails')
        .select()
        .eq('status', 'FAILED')
        .order('received_at', ascending: false)
        .limit(limit);
    return (rows as List).map((r) => FailedEmailRow.fromRow(r as Map<String, dynamic>)).toList();
  }

  /// FAILED (a matched parser blew up) and IGNORED (no parser matched) both
  /// surface here -- an IGNORED row isn't necessarily a problem (it might be
  /// an OTP that slipped past the SMS_SENDERS filter's substring match) but
  /// it might be a bank template the Laxmi parser doesn't know yet, and
  /// there was previously no way to tell the two apart from the app.
  Future<List<RawMessageIssueRow>> fetchRawMessageIssues({int limit = 100}) async {
    final rows = await _client
        .from('raw_messages')
        .select()
        .inFilter('status', ['FAILED', 'IGNORED'])
        .order('received_at', ascending: false)
        .limit(limit);
    return (rows as List).map((r) => RawMessageIssueRow.fromRow(r as Map<String, dynamic>)).toList();
  }
}

final dataHealthRepositoryProvider = Provider<DataHealthRepository>((ref) {
  return DataHealthRepository(ref.watch(supabaseClientProvider));
});

// All three of these change only as often as the daily worker run does --
// a 10-minute stale time means opening the Data Health screen twice in a
// sitting doesn't refetch it twice.

class _OpenLedgerGapsNotifier extends StaleAsyncNotifier<List<LedgerGapRow>> {
  @override
  Duration get staleTime => const Duration(minutes: 10);
  @override
  Future<List<LedgerGapRow>> fetch() => ref.read(dataHealthRepositoryProvider).fetchOpenGaps();
}

final openLedgerGapsProvider = AsyncNotifierProvider<_OpenLedgerGapsNotifier, List<LedgerGapRow>>(
  _OpenLedgerGapsNotifier.new,
);

class _FailedEmailsNotifier extends StaleAsyncNotifier<List<FailedEmailRow>> {
  @override
  Duration get staleTime => const Duration(minutes: 10);
  @override
  Future<List<FailedEmailRow>> fetch() => ref.read(dataHealthRepositoryProvider).fetchFailedEmails();
}

final failedEmailsProvider = AsyncNotifierProvider<_FailedEmailsNotifier, List<FailedEmailRow>>(
  _FailedEmailsNotifier.new,
);

class _RawMessageIssuesNotifier extends StaleAsyncNotifier<List<RawMessageIssueRow>> {
  @override
  Duration get staleTime => const Duration(minutes: 10);
  @override
  Future<List<RawMessageIssueRow>> fetch() => ref.read(dataHealthRepositoryProvider).fetchRawMessageIssues();
}

final rawMessageIssuesProvider =
    AsyncNotifierProvider<_RawMessageIssuesNotifier, List<RawMessageIssueRow>>(
  _RawMessageIssuesNotifier.new,
);
