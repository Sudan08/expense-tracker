import 'enums.dart';

/// A ledger row, plus the display fields pulled in via Supabase's nested
/// select (accounts(display_name), categories(name)) so screens don't need a
/// second round trip just to show a name.
class Txn {
  final String id;
  final String accountId;
  final String accountDisplayName;
  final DateTime occurredAt;
  final TimePrecision occurredPrecision;
  final Direction direction;
  final int amountPaisa;
  final int? balanceAfterPaisa;
  final String currency;
  final String? reference;
  final String descriptionRaw;
  final String? counterparty;
  final String? channel;
  /// The user's own note, typed in the app. Distinct from descriptionRaw,
  /// which is the bank's verbatim text and is owned by the parser.
  final String? userNote;
  final String? categoryId;
  final String? categoryName;
  final String? categorySource;
  final double? categoryConfidence;
  final String? transferGroupId;
  final bool excludedFromSpend;
  final TxnStatus status;
  /// PARSED for anything a parser produced from an email or SMS; MANUAL for
  /// a row typed in the app -- usually to fill a ledger gap the bank made
  /// and the pipeline never saw. Worth surfacing in the UI: a manual row is
  /// the user's own recollection, not the bank's statement.
  final EntrySource entrySource;

  Txn({
    required this.id,
    required this.accountId,
    required this.accountDisplayName,
    required this.occurredAt,
    required this.occurredPrecision,
    required this.direction,
    required this.amountPaisa,
    required this.balanceAfterPaisa,
    required this.currency,
    required this.reference,
    required this.descriptionRaw,
    required this.counterparty,
    required this.channel,
    required this.userNote,
    required this.categoryId,
    required this.categoryName,
    required this.categorySource,
    required this.categoryConfidence,
    required this.transferGroupId,
    required this.excludedFromSpend,
    required this.status,
    required this.entrySource,
  });

  bool get isTransfer => transferGroupId != null || excludedFromSpend;

  factory Txn.fromRow(Map<String, dynamic> row) {
    final account = row['accounts'] as Map<String, dynamic>?;
    final category = row['categories'] as Map<String, dynamic>?;
    return Txn(
      id: row['id'] as String,
      accountId: row['account_id'] as String,
      accountDisplayName: account?['display_name'] as String? ?? '—',
      occurredAt: DateTime.parse(row['occurred_at'] as String),
      occurredPrecision: timePrecisionFromDb(row['occurred_precision'] as String),
      direction: directionFromDb(row['direction'] as String),
      amountPaisa: row['amount_paisa'] as int,
      balanceAfterPaisa: row['balance_after_paisa'] as int?,
      currency: row['currency'] as String,
      reference: row['reference'] as String?,
      descriptionRaw: row['description_raw'] as String,
      counterparty: row['counterparty'] as String?,
      channel: row['channel'] as String?,
      userNote: row['user_note'] as String?,
      categoryId: row['category_id'] as String?,
      categoryName: category?['name'] as String?,
      categorySource: row['category_source'] as String?,
      categoryConfidence: (row['category_confidence'] as num?)?.toDouble(),
      transferGroupId: row['transfer_group_id'] as String?,
      excludedFromSpend: row['excluded_from_spend'] as bool,
      status: txnStatusFromDb(row['status'] as String),
      entrySource: entrySourceFromDb(row['entry_source'] as String? ?? 'PARSED'),
    );
  }
}
