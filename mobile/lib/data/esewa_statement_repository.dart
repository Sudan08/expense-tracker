import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/supabase/supabase_providers.dart';

/// `sender`/`channel` a staged eSewa statement row is tagged with. Must
/// match the worker's `SENDER` constant in
/// worker/src/expense_tracker/parsers/esewa_statement.py byte for byte --
/// that string is what `EsewaStatementFileParser.matches` keys on to find
/// this row among everything else in raw_messages.
const _sender = 'ESEWA_STATEMENT';

class EsewaStatementUploadResult {
  const EsewaStatementUploadResult({required this.fileName, required this.alreadyStaged});

  final String fileName;

  /// True if this exact file (by content_hash) was already staged --
  /// re-picking the same download is harmless, not an error.
  final bool alreadyStaged;
}

class EsewaStatementPickCancelled implements Exception {}

/// Stages a downloaded eSewa "Statement" export (Profile -> Statement ->
/// Excel in the eSewa app) as one raw_messages row, for the worker to parse
/// on its next sync.
///
/// Why the whole file rather than one row per transaction: there is no
/// robust reader for legacy .xls on Android/iOS worth shipping when the
/// worker already has one (xlrd, in Python). So unlike SMS -- where the
/// phone reads and stages many small text messages itself -- this uploads
/// the file's raw bytes untouched; parsers/esewa_statement.py on the worker
/// side is the only place a row of the spreadsheet actually gets read.
/// Invariant 8 ("the phone never writes financial facts") holds the same
/// way it does for SMS: this class stages bytes, it never decides what they
/// mean.
class EsewaStatementRepository {
  EsewaStatementRepository(this._client);

  final SupabaseClient _client;

  /// Opens a file picker, uploads whatever the user picked, and returns.
  /// Throws [EsewaStatementPickCancelled] if they backed out of the picker.
  Future<EsewaStatementUploadResult> pickAndUpload() async {
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['xls']);
    if (file == null) throw EsewaStatementPickCancelled();

    final bytes = await file.readAsBytes();
    final alreadyStaged = await _upload(bytes);
    return EsewaStatementUploadResult(fileName: file.name, alreadyStaged: alreadyStaged);
  }

  /// Returns true if this exact file's content_hash was already on file
  /// (nothing new inserted), matching sms_repository's upsert-dedupe shape.
  Future<bool> _upload(List<int> bytes) async {
    final inserted = await _client.from('raw_messages').upsert(
      {
        'user_id': _client.auth.currentUser!.id,
        'channel': _sender,
        'sender': _sender,
        'body': base64Encode(bytes),
        'received_at': DateTime.now().toUtc().toIso8601String(),
        'device': Platform.operatingSystem,
        'content_hash': sha256.convert(bytes).toString(),
      },
      onConflict: 'user_id,content_hash',
      ignoreDuplicates: true,
    ).select('id');
    return (inserted as List).isEmpty;
  }
}

final esewaStatementRepositoryProvider = Provider<EsewaStatementRepository>((ref) {
  return EsewaStatementRepository(ref.watch(supabaseClientProvider));
});
