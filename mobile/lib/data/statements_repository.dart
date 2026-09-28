import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/cache/stale_async_notifier.dart';
import '../core/supabase/supabase_providers.dart';

class UploadedStatementRow {
  const UploadedStatementRow({
    required this.id,
    required this.sender,
    required this.receivedAt,
    required this.status,
    this.templateKey,
    this.error,
    required this.txnCount,
    required this.contentHash,
  });

  factory UploadedStatementRow.fromRow(Map<String, dynamic> row) {
    return UploadedStatementRow(
      id: row['id'] as String,
      sender: row['sender'] as String,
      receivedAt: DateTime.parse(row['received_at'] as String),
      status: row['status'] as String,
      templateKey: row['template_key'] as String?,
      error: row['error'] as String?,
      txnCount: (row['txn_count'] as num?)?.toInt() ?? 0,
      contentHash: row['content_hash'] as String? ?? '',
    );
  }

  final String id;
  final String sender;
  final DateTime receivedAt;
  final String status;
  final String? templateKey;
  final String? error;
  final int txnCount;
  final String contentHash;

  String get displayName {
    if (sender == 'NABIL_STATEMENT') return 'Nabil Bank (.pdf)';
    if (sender == 'LAXMI_STATEMENT') return 'Laxmi Bank (.pdf)';
    if (sender == 'BANK_STATEMENT') return 'Bank Statement (.pdf)';
    if (sender == 'ESEWA_STATEMENT') return 'eSewa Statement (.xls)';
    return sender;
  }
}

class StatementUploadResult {
  const StatementUploadResult({
    required this.fileName,
    required this.alreadyStaged,
    required this.bankName,
  });
  final String fileName;
  final bool alreadyStaged;
  final String bankName;
}

class StatementsRepository {
  StatementsRepository(this._client);
  final SupabaseClient _client;

  Future<List<UploadedStatementRow>> fetchUploadedStatements({int limit = 50}) async {
    final rows = await _client
        .from('raw_messages')
        .select('id, sender, received_at, status, template_key, error, txn_count, content_hash')
        .inFilter('sender', ['NABIL_STATEMENT', 'LAXMI_STATEMENT', 'BANK_STATEMENT', 'ESEWA_STATEMENT'])
        .order('received_at', ascending: false)
        .limit(limit);

    return (rows as List)
        .map((r) => UploadedStatementRow.fromRow(r as Map<String, dynamic>))
        .toList();
  }

  Future<StatementUploadResult?> pickAndUploadBankPdf({String bank = 'AUTO'}) async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (files.isEmpty) return null;
    final file = files.first;

    String sender = 'BANK_STATEMENT';
    String bankDisplayName = 'Bank Statement';
    if (bank == 'NABIL') {
      sender = 'NABIL_STATEMENT';
      bankDisplayName = 'Nabil Bank';
    } else if (bank == 'LAXMI') {
      sender = 'LAXMI_STATEMENT';
      bankDisplayName = 'Laxmi Bank';
    } else {
      // Try to guess from filename if user picked Auto
      final nameLower = file.name.toLowerCase();
      if (nameLower.contains('laxmi') || nameLower.contains('sunrise')) {
        sender = 'LAXMI_STATEMENT';
        bankDisplayName = 'Laxmi Bank';
      } else if (nameLower.contains('nabil')) {
        sender = 'NABIL_STATEMENT';
        bankDisplayName = 'Nabil Bank';
      }
    }

    final bytes = await file.readAsBytes();
    final alreadyStaged = await _uploadStatement(
      sender: sender,
      bytes: bytes,
      fileName: file.name,
    );
    return StatementUploadResult(
      fileName: file.name,
      alreadyStaged: alreadyStaged,
      bankName: bankDisplayName,
    );
  }

  Future<StatementUploadResult?> pickAndUploadNabilPdf() => pickAndUploadBankPdf(bank: 'NABIL');
  Future<StatementUploadResult?> pickAndUploadLaxmiPdf() => pickAndUploadBankPdf(bank: 'LAXMI');

  Future<StatementUploadResult?> pickAndUploadEsewaXls() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xls'],
    );
    if (files.isEmpty) return null;
    final file = files.first;

    final bytes = await file.readAsBytes();
    final alreadyStaged = await _uploadStatement(
      sender: 'ESEWA_STATEMENT',
      bytes: bytes,
      fileName: file.name,
    );
    return StatementUploadResult(
      fileName: file.name,
      alreadyStaged: alreadyStaged,
      bankName: 'eSewa',
    );
  }

  Future<bool> _uploadStatement({
    required String sender,
    required List<int> bytes,
    required String fileName,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('Not signed in');

    final contentHash = sha256.convert(bytes).toString();

    // RLS: authenticated role has column-level insert on raw_messages without 'status'.
    // Postgres automatically defaults status to 'PENDING'.
    final inserted = await _client.from('raw_messages').upsert({
      'user_id': user.id,
      'channel': 'UPLOAD',
      'sender': sender,
      'body': base64Encode(bytes),
      'received_at': DateTime.now().toUtc().toIso8601String(),
      'device': Platform.operatingSystem,
      'content_hash': contentHash,
    }, onConflict: 'user_id,content_hash', ignoreDuplicates: true).select('id');

    return (inserted as List).isEmpty;
  }

  Future<String> exportTransactionsCsv() async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('Not signed in');

    final rows = await _client
        .from('transactions')
        .select('occurred_at, direction, amount_paisa, currency, counterparty, description_raw, status, entry_source')
        .order('occurred_at', ascending: false);

    final buffer = StringBuffer();
    buffer.writeln('occurred_at,direction,amount,amount_paisa,currency,counterparty,description,status,entry_source');

    for (final r in (rows as List)) {
      final map = r as Map<String, dynamic>;
      final paisa = (map['amount_paisa'] as num?)?.toInt() ?? 0;
      final amount = (paisa / 100).toStringAsFixed(2);
      final occurredAt = map['occurred_at'] ?? '';
      final direction = map['direction'] ?? '';
      final currency = map['currency'] ?? 'NPR';
      final counterparty = _escapeCsv(map['counterparty']?.toString() ?? '');
      final desc = _escapeCsv(map['description_raw']?.toString() ?? '');
      final status = map['status'] ?? '';
      final entrySource = map['entry_source'] ?? '';

      buffer.writeln('$occurredAt,$direction,$amount,$paisa,$currency,$counterparty,$desc,$status,$entrySource');
    }

    return buffer.toString();
  }

  String _escapeCsv(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}

final statementsRepositoryProvider = Provider<StatementsRepository>((ref) {
  return StatementsRepository(ref.watch(supabaseClientProvider));
});

class UploadedStatementsNotifier extends StaleAsyncNotifier<List<UploadedStatementRow>> {
  @override
  Duration get staleTime => const Duration(seconds: 30);

  @override
  Future<List<UploadedStatementRow>> fetch() {
    return ref.read(statementsRepositoryProvider).fetchUploadedStatements();
  }
}

final uploadedStatementsProvider =
    AsyncNotifierProvider<UploadedStatementsNotifier, List<UploadedStatementRow>>(
  UploadedStatementsNotifier.new,
);
