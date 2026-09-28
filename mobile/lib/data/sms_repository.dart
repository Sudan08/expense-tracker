import 'dart:convert';
import 'dart:io';

import 'package:another_telephony/telephony.dart' as tel;
import 'package:crypto/crypto.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/cache/stale_async_notifier.dart';
import '../core/supabase/supabase_providers.dart';

/// How far back a first scan reaches when raw_messages is still empty.
const _firstScanDays = 90;

/// Overlap re-scanned on every incremental pass. An SMS whose handset
/// timestamp lands a few seconds either side of the last upload would
/// otherwise fall through the gap; re-uploading it is free because
/// (user_id, content_hash) is unique and the insert ignores duplicates.
const _overlap = Duration(hours: 6);

class SmsScanResult {
  const SmsScanResult({
    required this.matched,
    required this.uploaded,
    required this.since,
  });

  /// Messages from whitelisted senders present on the device in the window.
  final int matched;

  /// Rows the insert actually created -- the rest were already uploaded.
  final int uploaded;
  final DateTime since;
}

class SmsPermissionDenied implements Exception {
  @override
  String toString() => 'SMS permission denied';
}

/// Android has stopped showing the READ_SMS dialog entirely.
///
/// After the user denies a runtime permission (twice on older versions, once
/// from Android 11), the OS marks it permanently denied: every subsequent
/// request returns "denied" *without* prompting, which is exactly the bare
/// `PlatformException(permission_denied, Permission Request Denied By
/// User.)` this screen was showing on every retry. The only way out is the
/// app's own settings page, so this is a distinct type and the UI offers
/// exactly that rather than a "Scan failed" message the user can do nothing
/// about.
class SmsPermissionPermanentlyDenied implements Exception {
  @override
  String toString() => 'SMS permission permanently denied';
}

class SmsSendersNotConfigured implements Exception {
  @override
  String toString() =>
      'No SMS_SENDERS configured in .env -- nothing will be uploaded';
}

/// Reads bank SMS off the handset and stages them in Supabase for the worker
/// to parse (plan: SMS ingest, migration 20260908010000).
///
/// Two rules this class exists to enforce:
///
/// 1. **Default deny on sender.** Only messages whose sender matches the
///    SMS_SENDERS whitelist are ever uploaded. Your inbox also holds OTPs,
///    delivery codes, and personal messages; an "upload everything and let
///    the parser sort it out" design would push all of that into a database
///    that syncs to the cloud. Bodies of non-matching messages are read into
///    memory to be filtered and never leave the device.
/// 2. **The phone stages, it does not decide.** These rows are raw text.
///    Only the worker parses them into transactions, so invariant 8 ("the
///    phone never writes financial facts") still holds.
class SmsRepository {
  SmsRepository(this._client, this._telephony);

  final SupabaseClient _client;
  final tel.Telephony _telephony;

  /// Sender IDs to collect, from .env (`SMS_SENDERS=LaxmiBank,LaxmiSunrise`).
  /// Matched case-insensitively as a substring, because handsets render the
  /// same alphanumeric sender inconsistently across carriers.
  List<String> get senders => (dotenv.env['SMS_SENDERS'] ?? '')
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toList();

  bool get isSupported => Platform.isAndroid;

  /// Ask for READ_SMS, distinguishing "not yet granted" from "Android will
  /// never ask again".
  ///
  /// Goes through permission_handler rather than
  /// `_telephony.requestSmsPermissions`: that getter collapses every outcome
  /// into a single bool (or a thrown PlatformException once permanently
  /// denied), with no way to tell whether asking again could possibly work.
  /// another_telephony still does the actual inbox read below -- it only
  /// needs the OS grant to exist, not to have requested it itself.
  Future<void> ensurePermission() async {
    if (!isSupported) throw SmsPermissionDenied();

    var status = await Permission.sms.status;
    if (status.isGranted) return;

    // isPermanentlyDenied only means anything *after* a request has already
    // been shown once -- a fresh install reports plain "denied" for both a
    // permission never asked about and one that's permanently off, so ask
    // first and re-read rather than trusting this check up front.
    if (!status.isPermanentlyDenied) {
      status = await Permission.sms.request();
    }
    if (status.isGranted) return;
    if (status.isPermanentlyDenied) throw SmsPermissionPermanentlyDenied();
    throw SmsPermissionDenied();
  }

  /// True if READ_SMS is already granted, without prompting. Used by the
  /// silent startup scan, which must never itself trigger the system dialog.
  Future<bool> hasPermission() async {
    if (!isSupported) return false;
    return (await Permission.sms.status).isGranted;
  }

  /// Send the user to this app's page in Android settings -- the only place
  /// a permanently-denied permission can be turned back on.
  Future<bool> openSettings() => openAppSettings();

  /// The watermark, read from what is actually in the database rather than
  /// from local state. If the app is reinstalled or its storage cleared, this
  /// still resumes in the right place -- and it can never claim to have
  /// uploaded something the server doesn't have.
  Future<DateTime?> lastUploadedAt() async {
    final rows = await _client
        .from('raw_messages')
        .select('received_at')
        .order('received_at', ascending: false)
        .limit(1);
    final list = rows as List;
    if (list.isEmpty) return null;
    return DateTime.parse((list.first as Map<String, dynamic>)['received_at'] as String);
  }

  /// Scan the handset inbox and upload anything new.
  ///
  /// [fullRescan] ignores the watermark and re-reads the whole inbox -- the
  /// backfill path for messages missed while the app was uninstalled or
  /// permission was off. It is safe to run any time: duplicates are dropped
  /// by the unique constraint, not by this code.
  Future<SmsScanResult> scanAndUpload({bool fullRescan = false}) async {
    if (!isSupported) {
      return SmsScanResult(matched: 0, uploaded: 0, since: DateTime.now());
    }
    final whitelist = senders;
    if (whitelist.isEmpty) throw SmsSendersNotConfigured();
    await ensurePermission();

    final since = fullRescan
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : (await lastUploadedAt())?.subtract(_overlap) ??
            DateTime.now().subtract(const Duration(days: _firstScanDays));

    final messages = await _telephony.getInboxSms(
      columns: [tel.SmsColumn.ADDRESS, tel.SmsColumn.BODY, tel.SmsColumn.DATE],
      filter: tel.SmsFilter.where(tel.SmsColumn.DATE)
          .greaterThan(since.millisecondsSinceEpoch.toString()),
      sortOrder: [tel.OrderBy(tel.SmsColumn.DATE, sort: tel.Sort.ASC)],
    );

    final rows = <Map<String, dynamic>>[];
    for (final m in messages) {
      final address = m.address;
      final body = m.body;
      final date = m.date;
      if (address == null || body == null || date == null) continue;

      final from = address.toLowerCase();
      if (!whitelist.any(from.contains)) continue;

      final receivedAt = DateTime.fromMillisecondsSinceEpoch(date, isUtc: true);
      rows.add({
        'user_id': _client.auth.currentUser!.id,
        'channel': 'SMS',
        'sender': address,
        'body': body,
        'received_at': receivedAt.toIso8601String(),
        'device': Platform.operatingSystem,
        'content_hash': contentHash(address, date, body),
      });
    }

    if (rows.isEmpty) {
      return SmsScanResult(matched: 0, uploaded: 0, since: since);
    }

    var uploaded = 0;
    // Chunked so a long backfill isn't one enormous request that times out
    // halfway and leaves an ambiguous outcome.
    for (var i = 0; i < rows.length; i += 100) {
      final chunk = rows.sublist(i, (i + 100).clamp(0, rows.length));
      final inserted = await _client.from('raw_messages').upsert(
            chunk,
            onConflict: 'user_id,content_hash',
            ignoreDuplicates: true,
          ).select('id');
      uploaded += (inserted as List).length;
    }

    return SmsScanResult(matched: rows.length, uploaded: uploaded, since: since);
  }

  /// Throttle for the unprompted scan, which now runs on every resume rather
  /// than only on a cold start. Bank SMS is the transport that arrives in
  /// seconds, so the whole point is that it is picked up promptly -- but
  /// "resumed" also fires when the user flicks to another app and straight
  /// back, and each scan costs an inbox read plus a watermark query. A minute
  /// is long enough to collapse that thrash and short enough that coming back
  /// to the app still feels like it just checked.
  static const _rescanThrottle = Duration(minutes: 1);
  DateTime? _lastScanAt;

  /// True if [scanIfAlreadyEnrolled] would do real work rather than being
  /// throttled away. Exposed so a deliberate, user-initiated scan can bypass
  /// the throttle without duplicating the rule.
  bool get isThrottled {
    final last = _lastScanAt;
    return last != null && DateTime.now().difference(last) < _rescanThrottle;
  }

  /// The startup scan. Never prompts: this runs unasked on every app open,
  /// and springing a permission dialog there -- or retrying against a
  /// permanently-denied one -- is how a permission gets denied for good in
  /// the first place. hasPermission() only reads the OS's existing grant,
  /// so a "not yet granted" or "permanently denied" phone just skips this
  /// silently. First-time enrolment, and recovering from a denial, both
  /// happen on the SMS screen, where the user actually asked for it.
  /// [force] skips the resume throttle, for a scan the user asked for.
  Future<SmsScanResult?> scanIfAlreadyEnrolled({bool force = false}) async {
    if (!isSupported || senders.isEmpty) return null;
    if (!force && isThrottled) return null;
    if (!await hasPermission()) return null;
    if (await lastUploadedAt() == null) return null;
    // Stamped before the scan, not after: a scan that throws still counts as
    // an attempt, so a persistently failing one can't spin on every resume.
    _lastScanAt = DateTime.now();
    return scanAndUpload();
  }

  /// What the worker made of what we uploaded -- the phone's view of
  /// invariant 6, so a message that never became a transaction is visible
  /// rather than just absent.
  Future<Map<String, int>> statusCounts() async {
    final rows = await _client.from('raw_messages').select('status');
    final counts = <String, int>{};
    for (final r in rows as List) {
      final status = (r as Map<String, dynamic>)['status'] as String;
      counts[status] = (counts[status] ?? 0) + 1;
    }
    return counts;
  }
}

/// sha256(sender | epoch millis | body), matching the column comment on
/// raw_messages.content_hash. Two handsets scanning the same message must
/// produce the same hash, so this must never include anything local -- no
/// device name, no scan time.
String contentHash(String sender, int epochMillis, String body) {
  return sha256.convert(utf8.encode('$sender|$epochMillis|$body')).toString();
}

final telephonyProvider = Provider<tel.Telephony>((ref) => tel.Telephony.instance);

final smsRepositoryProvider = Provider<SmsRepository>((ref) {
  return SmsRepository(
    ref.watch(supabaseClientProvider),
    ref.watch(telephonyProvider),
  );
});

class _SmsStatusCountsNotifier extends StaleAsyncNotifier<Map<String, int>> {
  @override
  Duration get staleTime => const Duration(minutes: 5);

  @override
  Future<Map<String, int>> fetch() => ref.read(smsRepositoryProvider).statusCounts();
}

final smsStatusCountsProvider =
    AsyncNotifierProvider<_SmsStatusCountsNotifier, Map<String, int>>(
  _SmsStatusCountsNotifier.new,
);
