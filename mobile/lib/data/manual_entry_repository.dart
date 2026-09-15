import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/supabase/supabase_providers.dart';
import '../models/enums.dart';
import '../models/manual_entry.dart';

/// Raised when the database refuses an insert because an identical entry is
/// already on file (unique violation on (user_id, dedupe_key)).
///
/// Worth its own type rather than a generic failure: this is overwhelmingly
/// a double-tap on Save, and telling the user "that's already recorded" is
/// the truth, where "could not save" would send them off to type it again.
class DuplicateManualEntry implements Exception {
  @override
  String toString() => 'An identical manual entry already exists';
}

/// Writes the user's own ledger entries, and closes the gaps they fill.
///
/// See supabase/migrations/20260913000000_manual_entries_and_gap_fill.sql for
/// why this is allowed to exist at all -- plan invariant 8 used to forbid the
/// phone inserting transactions outright, and that migration narrows it to
/// forbidding the phone inserting *parser-derived* transactions.
class ManualEntryRepository {
  ManualEntryRepository(this._client);
  final SupabaseClient _client;

  /// Insert one manual transaction; if it was filling a gap, mark that gap
  /// resolved. Returns the new transaction's id.
  ///
  /// These are two statements with no transaction around them, and that is
  /// survivable in exactly one direction. If the insert succeeds and the gap
  /// update then fails, the ledger has the entry and one gap is still flagged
  /// open -- which the next reconciler run closes on its own, because the
  /// pair it names is no longer consecutive (see
  /// pipeline/reconcile.py::reconcile_and_record_gaps). The reverse can't
  /// happen: nothing updates the gap unless the insert already returned an
  /// id. So the worst case is a stale flag for a few hours, never a lost
  /// entry or a gap closed over nothing.
  Future<String> record(ManualEntryDraft draft) async {
    final userId = _client.auth.currentUser!.id;
    final trimmedNote = draft.note?.trim();

    late final Map<String, dynamic> inserted;
    try {
      inserted = await _client.from('transactions').insert({
        'user_id': userId,
        'account_id': draft.accountId,
        'occurred_at': draft.occurredAt.toUtc().toIso8601String(),
        // The user picked a date and a time, so the ledger records that it
        // knows the minute -- but never the second, which no one types
        // (plan invariant 2: record the precision the source gave).
        'occurred_precision': 'MINUTE',
        'direction': directionToDb(draft.direction),
        'amount_paisa': draft.amountPaisa,
        'balance_after_paisa': draft.balanceAfterPaisa,
        'currency': draft.currency,
        'description_raw': draft.description.trim(),
        'counterparty': draft.description.trim(),
        'user_note': (trimmedNote == null || trimmedNote.isEmpty) ? null : trimmedNote,
        'category_id': draft.categoryId,
        // 'user' for the same reason the recategorize sheet writes it: the
        // categorizer must not later "improve" a choice a human made.
        'category_source': draft.categoryId == null ? null : 'user',
        // A row you typed yourself needs no review -- you are the review.
        // Uncategorized ones still go to the queue.
        'status': txnStatusToDb(
          draft.categoryId == null ? TxnStatus.needsReview : TxnStatus.confirmed,
        ),
        'dedupe_key': draft.dedupeKey,
        'entry_source': 'MANUAL',
      }).select('id').single();
    } on PostgrestException catch (e) {
      // 23505 = unique_violation. The only unique index reachable here is
      // (user_id, dedupe_key).
      if (e.code == '23505') throw DuplicateManualEntry();
      rethrow;
    }

    final txnId = inserted['id'] as String;

    if (draft.gapId != null) {
      await resolveGap(
        draft.gapId!,
        resolvedBy: 'MANUAL_ENTRY',
        note: 'Filled by hand: ${draft.description.trim()}',
      );
    }
    return txnId;
  }

  /// Close a gap. `resolvedBy` is 'MANUAL_ENTRY' when an entry filled it and
  /// 'DISMISSED' when the user decided to stop being asked -- the column
  /// keeps those apart so a dismissed gap never reads as a solved one.
  Future<void> resolveGap(
    String gapId, {
    required String resolvedBy,
    String? note,
  }) async {
    await _client.from('ledger_gaps').update({
      'resolved': true,
      'resolved_at': DateTime.now().toUtc().toIso8601String(),
      'resolved_by': resolvedBy,
      'resolution_note': note,
    }).eq('id', gapId);
  }
}

final manualEntryRepositoryProvider = Provider<ManualEntryRepository>((ref) {
  return ManualEntryRepository(ref.watch(supabaseClientProvider));
});
