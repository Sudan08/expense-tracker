/// A row of merchant_rules: "descriptions matching this pattern file under
/// this category." Created either by the worker's own rule-learning or by
/// the phone's recategorize correction loop (learned_from_user = true).
class MerchantRule {
  final String id;
  final String pattern;
  final String categoryId;
  final String? categoryName;
  final String? counterpartyLabel;
  final int priority;
  final bool learnedFromUser;
  final int hitCount;
  final DateTime createdAt;

  MerchantRule({
    required this.id,
    required this.pattern,
    required this.categoryId,
    this.categoryName,
    required this.counterpartyLabel,
    required this.priority,
    required this.learnedFromUser,
    required this.hitCount,
    required this.createdAt,
  });

  factory MerchantRule.fromRow(Map<String, dynamic> row) {
    final category = row['categories'] as Map<String, dynamic>?;
    return MerchantRule(
      id: row['id'] as String,
      pattern: row['pattern'] as String,
      categoryId: row['category_id'] as String,
      categoryName: category?['name'] as String?,
      counterpartyLabel: row['counterparty_label'] as String?,
      priority: row['priority'] as int,
      learnedFromUser: row['learned_from_user'] as bool,
      hitCount: row['hit_count'] as int,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }
}
