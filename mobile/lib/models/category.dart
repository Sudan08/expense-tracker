class Category {
  final String id;
  final String name;
  final String? parentId;
  final bool isSpend;

  Category({
    required this.id,
    required this.name,
    required this.parentId,
    required this.isSpend,
  });

  factory Category.fromRow(Map<String, dynamic> row) => Category(
        id: row['id'] as String,
        name: row['name'] as String,
        parentId: row['parent_id'] as String?,
        isSpend: row['is_spend'] as bool,
      );
}
