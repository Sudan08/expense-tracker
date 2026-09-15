import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'enums.dart';

/// A transaction the user is asserting themselves, either free-standing (a
/// cash spend no bank ever messaged about) or to fill a specific
/// ledger_gaps row.
///
/// This is the phone writing to the ledger, which migration
/// 20260913000000's header explains at length. The short version: it lands
/// as entry_source = 'MANUAL', it can never claim a source message or a
/// parser version, and the database enforces both.
class ManualEntryDraft {
  const ManualEntryDraft({
    required this.accountId,
    required this.occurredAt,
    required this.direction,
    required this.amountPaisa,
    required this.description,
    required this.currency,
    this.balanceAfterPaisa,
    this.categoryId,
    this.note,
    this.gapId,
  });

  final String accountId;

  /// When the transaction happened, not when it was typed. For a gap fill
  /// this must land strictly between the two transactions bracketing the
  /// gap, or the reconciler won't order it into the chain and the gap stays
  /// open -- GapFillForm clamps the picker to enforce that.
  final DateTime occurredAt;
  final Direction direction;
  final int amountPaisa;
  final String description;
  final String currency;

  /// The account balance immediately after this transaction.
  ///
  /// Null for a free-standing entry, and that is correct rather than lazy:
  /// reconcile.py skips rows with no balance instead of treating them as a
  /// break in the chain, so a cash entry with an invented balance would
  /// manufacture two gaps where there were none. Non-null only when filling
  /// a gap, where it is computed from the gap's own arithmetic and is the
  /// thing that lets the chain close.
  final int? balanceAfterPaisa;

  final String? categoryId;
  final String? note;

  /// The ledger_gaps row this entry was created to fill, if any.
  final String? gapId;

  int get signedPaisa => direction == Direction.credit ? amountPaisa : -amountPaisa;

  /// Content-derived, so tapping Save twice inserts one row rather than two:
  /// the second insert collides with the unique (user_id, dedupe_key) index
  /// and is refused by the database, not by a disabled button that a slow
  /// network can outrun.
  ///
  /// The 'manual:' prefix is required by the transactions_manual_dedupe_namespace
  /// constraint, and it is what guarantees a manual entry can never occupy
  /// the dedupe slot of a parsed transaction still to arrive -- parsers emit
  /// 'nabil:' and 'esewa:' keys.
  ///
  /// The note is part of the hash on purpose: two genuinely separate but
  /// otherwise identical entries (the same Rs. 50 tea, twice, in the same
  /// minute) are distinguishable by giving one of them a note, which is
  /// also the only way anyone would tell them apart later.
  String get dedupeKey {
    final canonical = [
      accountId,
      occurredAt.toUtc().toIso8601String(),
      directionToDb(direction),
      '$amountPaisa',
      currency,
      description.trim(),
      note?.trim() ?? '',
    ].join('|');
    return 'manual:${sha256.convert(utf8.encode(canonical))}';
  }
}
