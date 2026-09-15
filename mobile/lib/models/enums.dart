// Mirrors the Postgres enums in supabase/migrations/20260901000000_initial_schema.sql.
// Keep in sync by hand -- there's no codegen from the DB schema (yet).

enum AccountKind { bank, wallet }

AccountKind accountKindFromDb(String value) => switch (value) {
      'BANK' => AccountKind.bank,
      'WALLET' => AccountKind.wallet,
      _ => throw ArgumentError('unknown account_kind: $value'),
    };

enum Direction { debit, credit }

Direction directionFromDb(String value) => switch (value) {
      'DEBIT' => Direction.debit,
      'CREDIT' => Direction.credit,
      _ => throw ArgumentError('unknown direction: $value'),
    };

String directionToDb(Direction d) => d == Direction.debit ? 'DEBIT' : 'CREDIT';

enum TxnStatus { needsReview, categorized, confirmed }

TxnStatus txnStatusFromDb(String value) => switch (value) {
      'NEEDS_REVIEW' => TxnStatus.needsReview,
      'CATEGORIZED' => TxnStatus.categorized,
      'CONFIRMED' => TxnStatus.confirmed,
      _ => throw ArgumentError('unknown txn_status: $value'),
    };

String txnStatusToDb(TxnStatus s) => switch (s) {
      TxnStatus.needsReview => 'NEEDS_REVIEW',
      TxnStatus.categorized => 'CATEGORIZED',
      TxnStatus.confirmed => 'CONFIRMED',
    };

enum TimePrecision { second, minute, day }

TimePrecision timePrecisionFromDb(String value) => switch (value) {
      'SECOND' => TimePrecision.second,
      'MINUTE' => TimePrecision.minute,
      'DAY' => TimePrecision.day,
      _ => throw ArgumentError('unknown time_precision: $value'),
    };

/// Where a ledger row came from. Mirrors transactions.entry_source, added in
/// migration 20260913000000 along with the narrowing of invariant 8: the
/// phone may write its own assertions, provided they are labelled as such
/// and can never claim a parser's provenance.
enum EntrySource { parsed, manual }

EntrySource entrySourceFromDb(String value) => switch (value) {
      'PARSED' => EntrySource.parsed,
      'MANUAL' => EntrySource.manual,
      _ => throw ArgumentError('unknown entry_source: $value'),
    };
