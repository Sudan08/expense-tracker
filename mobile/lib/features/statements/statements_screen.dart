import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/async_value_view.dart';
import '../../core/time_ago.dart';
import '../../data/statements_repository.dart';

class StatementsScreen extends ConsumerStatefulWidget {
  const StatementsScreen({super.key});

  @override
  ConsumerState<StatementsScreen> createState() => _StatementsScreenState();
}

class _StatementsScreenState extends ConsumerState<StatementsScreen> {
  bool _uploadingBankPdf = false;
  bool _uploadingEsewa = false;
  bool _exportingCsv = false;
  String _selectedBank = 'AUTO';
  String? _statusMessage;

  Future<void> _uploadBankPdf() async {
    setState(() {
      _uploadingBankPdf = true;
      _statusMessage = null;
    });

    try {
      final repo = ref.read(statementsRepositoryProvider);
      final result = await repo.pickAndUploadBankPdf(bank: _selectedBank);
      if (!mounted) return;

      if (result == null) {
        setState(() => _uploadingBankPdf = false);
        return;
      }

      ref.invalidate(uploadedStatementsProvider);
      setState(() {
        _uploadingBankPdf = false;
        _statusMessage = result.alreadyStaged
            ? '${result.fileName} was already uploaded previously.'
            : '${result.bankName} statement (${result.fileName}) uploaded! The worker will verify transactions on the next sync.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_statusMessage!)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploadingBankPdf = false;
        _statusMessage = 'Upload failed: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_statusMessage!)),
      );
    }
  }

  Future<void> _uploadEsewa() async {
    setState(() {
      _uploadingEsewa = true;
      _statusMessage = null;
    });

    try {
      final repo = ref.read(statementsRepositoryProvider);
      final result = await repo.pickAndUploadEsewaXls();
      if (!mounted) return;

      if (result == null) {
        setState(() => _uploadingEsewa = false);
        return;
      }

      ref.invalidate(uploadedStatementsProvider);
      setState(() {
        _uploadingEsewa = false;
        _statusMessage = result.alreadyStaged
            ? '${result.fileName} was already uploaded previously.'
            : 'eSewa statement (${result.fileName}) uploaded! The worker will parse it on the next sync.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_statusMessage!)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploadingEsewa = false;
        _statusMessage = 'Upload failed: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_statusMessage!)),
      );
    }
  }

  Future<void> _exportCsv() async {
    setState(() => _exportingCsv = true);
    try {
      final csv = await ref.read(statementsRepositoryProvider).exportTransactionsCsv();
      if (!mounted) return;

      await Clipboard.setData(ClipboardData(text: csv));
      setState(() => _exportingCsv = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Transactions CSV copied to clipboard! You can paste it into Excel or a spreadsheet.'),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _exportingCsv = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statements = ref.watch(uploadedStatementsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Statements & Exports')),
      body: RefreshIndicator(
        onRefresh: () => ref.read(uploadedStatementsProvider.notifier).refresh(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Bank statement verification', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Upload statements exported from your bank or wallet. The worker parses '
              'them, verifies all transactions against your database, and automatically fills any ledger gaps.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),

            // Generic Bank Statement PDF Card
            Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.picture_as_pdf_outlined, color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        Text('Bank Statement (.pdf)', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Export your monthly statement PDF from Mobile Banking or NetBanking. '
                      'Works with Nabil Bank, Laxmi Sunrise Bank, and standard bank statements.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    Text('Select Bank:', style: theme.textTheme.labelMedium),
                    const SizedBox(height: 6),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'AUTO', label: Text('Auto-detect')),
                          ButtonSegment(value: 'NABIL', label: Text('Nabil Bank')),
                          ButtonSegment(value: 'LAXMI', label: Text('Laxmi Bank')),
                        ],
                        selected: {_selectedBank},
                        onSelectionChanged: (set) {
                          if (set.isNotEmpty) {
                            setState(() => _selectedBank = set.first);
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: _uploadingBankPdf ? null : _uploadBankPdf,
                      icon: _uploadingBankPdf
                          ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.upload_file),
                      label: Text(
                        _selectedBank == 'NABIL'
                            ? 'Upload Nabil statement (.pdf)'
                            : _selectedBank == 'LAXMI'
                                ? 'Upload Laxmi statement (.pdf)'
                                : 'Upload bank statement (.pdf)',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // eSewa XLS Card
            Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.table_chart_outlined, color: theme.colorScheme.secondary),
                        const SizedBox(width: 8),
                        Text('eSewa Wallet (.xls)', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Export statement from eSewa app (Profile → Statement → Excel icon). '
                      'Carries wallet-to-wallet transfers that never send emails.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _uploadingEsewa ? null : _uploadEsewa,
                      icon: _uploadingEsewa
                          ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.file_upload_outlined),
                      label: const Text('Upload eSewa statement (.xls)'),
                    ),
                  ],
                ),
              ),
            ),

            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              Text(_statusMessage!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
            ],

            const SizedBox(height: 28),
            const Divider(),
            const SizedBox(height: 20),

            // Staged Statements Section
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Uploaded statements', style: theme.textTheme.titleMedium),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: 'Refresh status',
                  onPressed: () => ref.read(uploadedStatementsProvider.notifier).refresh(),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Files staged for the worker. Status updates on each sync run.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            AsyncValueView(
              value: statements,
              data: (rows) => rows.isEmpty
                  ? Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'No statements uploaded yet. When you upload an exported statement, it will appear here.',
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  : Column(children: [for (final r in rows) _StatementTile(row: r)]),
              loading: () => const LinearProgressIndicator(),
              error: (e) => Text('Could not load statements: $e', style: TextStyle(color: theme.colorScheme.error)),
            ),

            const SizedBox(height: 28),
            const Divider(),
            const SizedBox(height: 20),

            // Export Section
            Text('Export your ledger', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Export all recorded transactions from the expense tracker for backup or analysis in Excel.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              child: ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Export all transactions to CSV'),
                subtitle: const Text('Copies full ledger (dates, exact paisa, currency, description) to clipboard'),
                trailing: _exportingCsv
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.copy_outlined),
                onTap: _exportingCsv ? null : _exportCsv,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatementTile extends StatelessWidget {
  const _StatementTile({required this.row});
  final UploadedStatementRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPending = row.status == 'PENDING';
    final isParsed = row.status == 'PARSED';
    final isFailed = row.status == 'FAILED';

    Color statusColor;
    IconData statusIcon;
    String statusText;

    if (isPending) {
      statusColor = Colors.orange;
      statusIcon = Icons.hourglass_top_outlined;
      statusText = 'Pending sync';
    } else if (isParsed) {
      statusColor = Colors.green;
      statusIcon = Icons.check_circle_outline;
      statusText = row.txnCount > 0 ? 'Verified (${row.txnCount} txns)' : 'Verified';
    } else if (isFailed) {
      statusColor = theme.colorScheme.error;
      statusIcon = Icons.error_outline;
      statusText = 'Failed';
    } else {
      statusColor = theme.colorScheme.onSurfaceVariant;
      statusIcon = Icons.info_outline;
      statusText = row.status;
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(
          row.sender.contains('STATEMENT') && !row.sender.contains('ESEWA')
              ? Icons.picture_as_pdf_outlined
              : Icons.table_chart_outlined,
          color: theme.colorScheme.primary,
        ),
        title: Text(row.displayName),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text('Uploaded ${timeAgo(row.receivedAt)}', style: theme.textTheme.bodySmall),
            if (row.error != null) ...[
              const SizedBox(height: 2),
              Text(row.error!, style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
            ],
          ],
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(statusIcon, size: 14, color: statusColor),
              const SizedBox(width: 4),
              Text(
                statusText,
                style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
