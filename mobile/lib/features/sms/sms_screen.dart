import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/async_value_view.dart';
import '../../data/esewa_statement_repository.dart';
import '../../data/sms_repository.dart';

/// Two ways of staging raw material for the worker to parse: SMS-only banks
/// (Laxmi), and an eSewa statement export -- the only source for a
/// wallet-to-wallet transfer, which eSewa never emails or texts at all. Both
/// land in the same raw_messages table, so `smsStatusCountsProvider`'s
/// "Staged messages" counts below already cover both without change.
class SmsScreen extends ConsumerStatefulWidget {
  const SmsScreen({super.key});

  @override
  ConsumerState<SmsScreen> createState() => _SmsScreenState();
}

class _SmsScreenState extends ConsumerState<SmsScreen> {
  bool _scanning = false;
  String? _lastMessage;
  // Set only for SmsPermissionPermanentlyDenied -- the one failure a retry
  // of the same button can never fix, because Android has stopped showing
  // the dialog at all. Every other error clears this on the next attempt.
  bool _permanentlyDenied = false;

  Future<void> _scan({required bool fullRescan}) async {
    setState(() {
      _scanning = true;
      _lastMessage = null;
      _permanentlyDenied = false;
    });
    try {
      final result = await ref.read(smsRepositoryProvider).scanAndUpload(fullRescan: fullRescan);
      ref.invalidate(smsStatusCountsProvider);
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _lastMessage = result.matched == 0
            ? 'No matching messages found on this device.'
            : 'Found ${result.matched}, uploaded ${result.uploaded} new '
                '(${result.matched - result.uploaded} already staged).';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _permanentlyDenied = e is SmsPermissionPermanentlyDenied;
        _lastMessage = e is SmsPermissionPermanentlyDenied
            ? "Android has turned off the SMS permission dialog for this app. "
                "Open Settings and allow it there, then come back and scan."
            : e is SmsPermissionDenied
                ? 'SMS permission denied. Tap Scan again to be asked.'
                : e is SmsSendersNotConfigured
                    ? 'Set SMS_SENDERS in the app .env (e.g. SMS_SENDERS=LaxmiBank) and rebuild.'
                    : 'Scan failed: $e';
      });
    }
  }

  bool _uploadingStatement = false;
  String? _statementMessage;

  Future<void> _uploadStatement() async {
    setState(() {
      _uploadingStatement = true;
      _statementMessage = null;
    });
    try {
      final result = await ref.read(esewaStatementRepositoryProvider).pickAndUpload();
      ref.invalidate(smsStatusCountsProvider);
      if (!mounted) return;
      setState(() {
        _uploadingStatement = false;
        _statementMessage = result.alreadyStaged
            ? '${result.fileName} was already staged -- nothing new to parse.'
            : '${result.fileName} staged. The worker parses it on its next sync.';
      });
    } on EsewaStatementPickCancelled {
      if (!mounted) return;
      setState(() => _uploadingStatement = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploadingStatement = false;
        _statementMessage = 'Upload failed: $e';
      });
    }
  }

  Future<void> _openSettings() async {
    // openAppSettings()'s future resolves once the settings screen has
    // launched, not once the user has left it -- there's no callback for
    // "they came back" to auto-rescan on, so this just opens the page and
    // leaves the Scan button as the next step once they return.
    await ref.read(smsRepositoryProvider).openSettings();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(smsRepositoryProvider);
    final counts = ref.watch(smsStatusCountsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Data import')),
      body: RefreshIndicator(
        onRefresh: () => ref.read(smsStatusCountsProvider.notifier).refresh(),
        child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Bank SMS', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Some banks (Laxmi) send SMS and never email. This device reads '
            'those messages and stages the raw text; the worker parses them '
            'into transactions on its next run.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          if (!repo.isSupported)
            const _Note('Reading SMS is Android-only. On this platform the '
                'staging table stays empty.')
          else if (repo.senders.isEmpty)
            const _Note('No senders configured. Set SMS_SENDERS in the app '
                '.env (comma-separated, e.g. SMS_SENDERS=LaxmiBank) and '
                'rebuild — nothing is uploaded until you do.')
          else
            _Note('Collecting from: ${repo.senders.join(', ')}. '
                'Messages from any other sender are never uploaded.'),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _scanning || !repo.isSupported ? null : () => _scan(fullRescan: false),
            icon: _scanning
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            label: const Text('Scan for new messages'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _scanning || !repo.isSupported ? null : () => _scan(fullRescan: true),
            icon: const Icon(Icons.history),
            label: const Text('Full inbox re-scan (backfill)'),
          ),
          if (_lastMessage != null) ...[
            const SizedBox(height: 16),
            Text(_lastMessage!, style: theme.textTheme.bodyMedium),
          ],
          if (_permanentlyDenied) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Open app settings'),
            ),
          ],
          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 20),
          Text('eSewa statement', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'eSewa never emails or texts a wallet-to-wallet transfer -- the '
            'Statement export (eSewa app: profile photo -> Statement -> '
            'Excel icon) is the only place it shows up. Download it there, '
            'then pick that file here; the worker parses it on its next '
            'sync, same as an SMS.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _uploadingStatement ? null : _uploadStatement,
            icon: _uploadingStatement
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.upload_file),
            label: const Text('Import eSewa statement (.xls)'),
          ),
          if (_statementMessage != null) ...[
            const SizedBox(height: 16),
            Text(_statementMessage!, style: theme.textTheme.bodyMedium),
          ],
          const SizedBox(height: 28),
          Text('Staged messages', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          AsyncValueView(
            value: counts,
            data: (byStatus) => byStatus.isEmpty
                ? Text('Nothing staged yet.', style: theme.textTheme.bodyMedium)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final entry in byStatus.entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              SizedBox(width: 120, child: Text(_statusLabel(entry.key))),
                              Text('${entry.value}'),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        'Ignored means no parser recognised the message yet. '
                        'The body is kept, so writing the parser later picks '
                        'these up without rescanning the phone.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            ),
            error: (e) => Text('Could not load status: $e'),
          ),
        ],
        ),
      ),
    );
  }

  String _statusLabel(String status) => switch (status) {
        'PENDING' => 'Waiting',
        'PARSED' => 'Parsed',
        'FAILED' => 'Failed',
        'IGNORED' => 'Ignored',
        _ => status,
      };
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
