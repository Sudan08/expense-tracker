import 'enums.dart';

class Account {
  final String id;
  final AccountKind kind;
  final String institution;
  final String? mask;
  final String displayName;
  final String currency;

  Account({
    required this.id,
    required this.kind,
    required this.institution,
    required this.mask,
    required this.displayName,
    required this.currency,
  });

  factory Account.fromRow(Map<String, dynamic> row) => Account(
        id: row['id'] as String,
        kind: accountKindFromDb(row['kind'] as String),
        institution: row['institution'] as String,
        mask: row['mask'] as String?,
        displayName: row['display_name'] as String,
        currency: row['currency'] as String,
      );
}
