// The three "something didn't make it into the ledger" tables that had no
// UI before this: ledger_gaps, processed_emails (FAILED), raw_messages
// (FAILED / IGNORED). See docs/APP_IMPROVEMENTS.md section 5 -- the
// architecture promises nothing is silently dropped (plan invariant 6), and
// none of that was visible from the app.

import 'enums.dart';

/// One unresolved balance discontinuity, read from v_open_ledger_gaps
/// (migration 20260913000000) rather than from ledger_gaps directly -- the
/// view already joins the two bracketing transactions, whose timestamps and
/// balances the gap-fill form needs to do its arithmetic.
class LedgerGapRow {
  final String id;
  final String accountId;
  final String accountDisplayName;
  final String currency;

  /// Signed, and the sign is the whole message: negative means money left
  /// the account and no DEBIT was ever recorded for it; positive means money
  /// arrived with no CREDIT. See [missingDirection].
  final int missingPaisa;
  final DateTime detectedAt;

  final String afterTxnId;
  final DateTime afterOccurredAt;

  /// The balance the bank reported after the last transaction the pipeline
  /// *did* see. Every manual entry filling this gap chains forward from
  /// here -- see ManualEntryDraft.balanceAfterPaisa.
  final int? afterBalancePaisa;

  final String beforeTxnId;
  final DateTime beforeOccurredAt;
  final int? beforeBalancePaisa;

  LedgerGapRow({
    required this.id,
    required this.accountId,
    required this.accountDisplayName,
    required this.currency,
    required this.missingPaisa,
    required this.detectedAt,
    required this.afterTxnId,
    required this.afterOccurredAt,
    required this.afterBalancePaisa,
    required this.beforeTxnId,
    required this.beforeOccurredAt,
    required this.beforeBalancePaisa,
  });

  /// What kind of transaction is missing. Money that left the account
  /// without a DEBIT on file is the overwhelmingly common case (a card
  /// swipe whose alert never sent); a missing CREDIT means money arrived
  /// unannounced.
  Direction get missingDirection => missingPaisa < 0 ? Direction.debit : Direction.credit;

  /// Always positive -- the amount to show and to pre-fill the form with.
  int get missingAmountPaisa => missingPaisa.abs();

  /// Whether there is room to place a transaction strictly inside the
  /// window. The reconciler orders by occurred_at, so an entry must fall
  /// between the two bracketing rows to become part of the chain; when the
  /// bank stamped both to the same minute there is nowhere to put it.
  bool get hasRoom => beforeOccurredAt.difference(afterOccurredAt).inSeconds >= 2;

  factory LedgerGapRow.fromRow(Map<String, dynamic> row) => LedgerGapRow(
        id: row['id'] as String,
        accountId: row['account_id'] as String,
        accountDisplayName: row['account_display_name'] as String? ?? '—',
        currency: row['currency'] as String? ?? 'NPR',
        missingPaisa: (row['missing_paisa'] as num).toInt(),
        detectedAt: DateTime.parse(row['detected_at'] as String),
        afterTxnId: row['after_txn_id'] as String,
        afterOccurredAt: DateTime.parse(row['after_occurred_at'] as String),
        afterBalancePaisa: (row['after_balance_paisa'] as num?)?.toInt(),
        beforeTxnId: row['before_txn_id'] as String,
        beforeOccurredAt: DateTime.parse(row['before_occurred_at'] as String),
        beforeBalancePaisa: (row['before_balance_paisa'] as num?)?.toInt(),
      );
}

class FailedEmailRow {
  final String messageId;
  final DateTime receivedAt;
  final String fromAddr;
  final String? templateKey;
  final String? error;

  FailedEmailRow({
    required this.messageId,
    required this.receivedAt,
    required this.fromAddr,
    required this.templateKey,
    required this.error,
  });

  factory FailedEmailRow.fromRow(Map<String, dynamic> row) => FailedEmailRow(
        messageId: row['message_id'] as String,
        receivedAt: DateTime.parse(row['received_at'] as String),
        fromAddr: row['from_addr'] as String,
        templateKey: row['template_key'] as String?,
        error: row['error'] as String?,
      );
}

class RawMessageIssueRow {
  final String id;
  final String status;
  final String sender;
  final DateTime receivedAt;
  final String? error;
  final String bodyPreview;

  RawMessageIssueRow({
    required this.id,
    required this.status,
    required this.sender,
    required this.receivedAt,
    required this.error,
    required this.bodyPreview,
  });

  factory RawMessageIssueRow.fromRow(Map<String, dynamic> row) {
    final body = row['body'] as String;
    return RawMessageIssueRow(
      id: row['id'] as String,
      status: row['status'] as String,
      sender: row['sender'] as String,
      receivedAt: DateTime.parse(row['received_at'] as String),
      error: row['error'] as String?,
      bodyPreview: body.length > 80 ? '${body.substring(0, 80)}…' : body,
    );
  }
}
