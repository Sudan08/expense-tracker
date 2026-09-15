class SyncRun {
  final String machine;
  final DateTime startedAt;
  final DateTime? completedAt;
  final int fetched;
  final int parsed;
  final int failed;
  final int txnsInserted;
  final String? error;

  SyncRun({
    required this.machine,
    required this.startedAt,
    required this.completedAt,
    required this.fetched,
    required this.parsed,
    required this.failed,
    required this.txnsInserted,
    required this.error,
  });

  factory SyncRun.fromRow(Map<String, dynamic> row) => SyncRun(
        machine: row['machine'] as String,
        startedAt: DateTime.parse(row['started_at'] as String),
        completedAt: row['completed_at'] == null ? null : DateTime.parse(row['completed_at'] as String),
        fetched: row['fetched'] as int,
        parsed: row['parsed'] as int,
        failed: row['failed'] as int,
        txnsInserted: row['txns_inserted'] as int,
        error: row['error'] as String?,
      );
}
