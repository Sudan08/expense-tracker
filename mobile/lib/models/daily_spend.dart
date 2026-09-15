/// One row of v_daily_spend: total DEBIT spend for one Kathmandu calendar
/// day, one currency. Powers the heatmap -- see
/// features/dashboard/widgets/spend_heatmap.dart.
class DailySpend {
  final DateTime day;
  final String currency;
  final int spentPaisa;
  final int txnCount;

  DailySpend({
    required this.day,
    required this.currency,
    required this.spentPaisa,
    required this.txnCount,
  });

  factory DailySpend.fromRow(Map<String, dynamic> row) {
    return DailySpend(
      day: DateTime.parse(row['day'] as String),
      currency: row['currency'] as String,
      spentPaisa: (row['spent_paisa'] as num?)?.toInt() ?? 0,
      txnCount: (row['txn_count'] as num?)?.toInt() ?? 0,
    );
  }
}
