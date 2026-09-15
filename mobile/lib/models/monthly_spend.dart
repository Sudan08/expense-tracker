/// One row of v_monthly_spend: spend/receipts for one category, one month,
/// **one currency**. category_id is nullable in the view (uncategorized
/// transactions still sum).
///
/// currency is part of the view's GROUP BY (migration
/// 20260908020000_currency_fix_and_merchant_rules_rw.sql) rather than
/// converted to NPR at query time -- there is no exchange rate anywhere in
/// this pipeline, and a screen that silently added a USD row to an NPR total
/// was the bug that migration fixed. Callers that want one number per
/// category must decide explicitly how to combine currencies (see
/// DashboardRepository.monthlySpend), not rely on the view to have done it.
///
/// The view has no FK metadata for PostgREST to embed categories(name)
/// automatically, so categoryName is filled in client-side by the
/// repository after a separate categories lookup -- see
/// DashboardRepository.monthlySpend.
class MonthlySpend {
  final DateTime month;
  final String? categoryId;
  String? categoryName;
  final String currency;
  final int spentPaisa;
  final int receivedPaisa;
  final int txnCount;

  MonthlySpend({
    required this.month,
    required this.categoryId,
    this.categoryName,
    required this.currency,
    required this.spentPaisa,
    required this.receivedPaisa,
    required this.txnCount,
  });

  factory MonthlySpend.fromRow(Map<String, dynamic> row) {
    return MonthlySpend(
      month: DateTime.parse(row['month'] as String),
      categoryId: row['category_id'] as String?,
      currency: row['currency'] as String,
      spentPaisa: (row['spent_paisa'] as num?)?.toInt() ?? 0,
      receivedPaisa: (row['received_paisa'] as num?)?.toInt() ?? 0,
      txnCount: row['txn_count'] as int,
    );
  }
}
