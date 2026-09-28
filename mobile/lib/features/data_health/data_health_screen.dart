import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/cache/async_value_view.dart';
import '../../core/money.dart';
import '../../core/time_ago.dart';
import '../../data/data_health_repository.dart';
import '../../data/manual_entry_repository.dart';
import '../../data/sync_repository.dart';
import '../../models/data_health.dart';
import '../../models/enums.dart';

/// Everything the pipeline recorded about what didn't make it into the
/// ledger, previously invisible from the app: unresolved ledger_gaps,
/// failed email parses, and failed/ignored SMS. Read-only, and it stays
/// that way -- these tables are the worker's own bookkeeping, and nothing
/// here is a financial fact the phone should be able to change.
/// See docs/APP_IMPROVEMENTS.md section 5.
class DataHealthScreen extends ConsumerWidget {
  const DataHealthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lastRun = ref.watch(lastSyncRunProvider);
    final gaps = ref.watch(openLedgerGapsProvider);
    final failedEmails = ref.watch(failedEmailsProvider);
    final smsIssues = ref.watch(rawMessageIssuesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Data health')),
      body: RefreshIndicator(
        onRefresh: () => Future.wait([
          ref.read(lastSyncRunProvider.notifier).refresh(),
          ref.read(openLedgerGapsProvider.notifier).refresh(),
          ref.read(failedEmailsProvider.notifier).refresh(),
          ref.read(rawMessageIssuesProvider.notifier).refresh(),
        ]),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _LastSyncCard(lastRun: lastRun),
            const SizedBox(height: 24),
            _Section(
              title: 'Unresolved ledger gaps',
              subtitle: 'A jump in your balance with no matching transaction — '
                  'money moved and the pipeline never saw why. Tap one to look '
                  'it up in your bank app and record it yourself.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AsyncValueView(
                    value: gaps,
                    data: (rows) => rows.isEmpty
                        ? const _AllClear('No open gaps.')
                        : Column(children: [for (final g in rows) _GapTile(gap: g)]),
                    loading: () => const _SectionLoading(),
                    error: (e) => _SectionError(e),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    elevation: 0,
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    child: ListTile(
                      leading: const Icon(Icons.receipt_long_outlined),
                      title: const Text('Resolve gaps with bank statement'),
                      subtitle: const Text('Upload monthly PDF/XLS export to verify and close gaps'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/statements'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _Section(
              title: 'Failed email parses',
              subtitle: 'An email matched a bank sender but the parser threw '
                  'an error -- the transaction inside it is missing.',
              child: AsyncValueView(
                value: failedEmails,
                data: (rows) => rows.isEmpty
                    ? const _AllClear('No failed emails.')
                    : Column(children: [for (final e in rows) _FailedEmailTile(row: e)]),
                loading: () => const _SectionLoading(),
                error: (e) => _SectionError(e),
              ),
            ),
            const SizedBox(height: 24),
            _Section(
              title: 'SMS not turned into transactions',
              subtitle: 'IGNORED means no parser recognised the sender/body '
                  'yet (the Laxmi parser is still being built). FAILED means '
                  'a parser matched but threw an error.',
              child: AsyncValueView(
                value: smsIssues,
                data: (rows) => rows.isEmpty
                    ? const _AllClear('Nothing outstanding.')
                    : Column(children: [for (final r in rows) _SmsIssueTile(row: r)]),
                loading: () => const _SectionLoading(),
                error: (e) => _SectionError(e),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LastSyncCard extends StatelessWidget {
  const _LastSyncCard({required this.lastRun});
  final AsyncValue lastRun;

  @override
  Widget build(BuildContext context) {
    return AsyncValueView(
      value: lastRun,
      data: (run) {
        if (run == null) {
          return const Text('No sync has run yet.');
        }
        final failed = run.error != null;
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.cloud_done_outlined,
                color: failed ? Theme.of(context).colorScheme.error : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  failed
                      ? 'Last sync (${run.machine}) ${timeAgo(run.completedAt ?? run.startedAt)} '
                          'failed: ${run.error}'
                      : 'Last synced from ${run.machine} ${timeAgo(run.completedAt ?? run.startedAt)} '
                          '· ${run.fetched} fetched, ${run.parsed} parsed, ${run.failed} failed',
                ),
              ),
            ],
          ),
        );
      },
      loading: () => const LinearProgressIndicator(),
      error: (e) => Text('Could not check sync status: $e'),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.subtitle, required this.child});
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _SectionLoading extends StatelessWidget {
  const _SectionLoading();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: LinearProgressIndicator(),
      );
}

class _SectionError extends StatelessWidget {
  const _SectionError(this.error);
  final Object error;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('Could not load: $error', style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
}

class _AllClear extends StatelessWidget {
  const _AllClear(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Text(text),
          ],
        ),
      );
}

/// A gap is the one row on this screen the user can actually do something
/// about, so unlike its read-only neighbours it is a button. Tapping opens
/// the fill form pre-loaded with the reconciler's arithmetic; the overflow
/// dismisses it for the cases no entry will ever explain.
class _GapTile extends ConsumerWidget {
  const _GapTile({required this.gap});
  final LedgerGapRow gap;

  Future<void> _dismiss(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop asking about this gap?'),
        content: const Text(
          'The money still moved — dismissing only stops the reminder. Your '
          'totals for that period stay incomplete, and nothing is deleted.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Dismiss')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(manualEntryRepositoryProvider).resolveGap(gap.id, resolvedBy: 'DISMISSED');
    await ref.read(openLedgerGapsProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final fmt = DateFormat.yMMMd();
    final window = '${fmt.format(gap.afterOccurredAt.toLocal())} → '
        '${fmt.format(gap.beforeOccurredAt.toLocal())}';
    final out = gap.missingDirection == Direction.debit;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/gaps/${gap.id}/fill'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          formatPaisa(gap.missingAmountPaisa, currency: gap.currency),
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          out ? 'went out' : 'came in',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${gap.accountDisplayName} · $window',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Tap to check your bank app and record it',
                      style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 20),
                tooltip: 'Gap options',
                onSelected: (value) {
                  if (value == 'dismiss') _dismiss(context, ref);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'dismiss', child: Text("Can't explain it — dismiss")),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FailedEmailTile extends StatelessWidget {
  const _FailedEmailTile({required this.row});
  final FailedEmailRow row;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.mail_outline),
        title: Text(row.fromAddr),
        subtitle: Text(
          '${row.templateKey ?? 'unrecognised template'} · ${timeAgo(row.receivedAt)}'
          '${row.error != null ? '\n${row.error}' : ''}',
        ),
        isThreeLine: row.error != null,
      ),
    );
  }
}

class _SmsIssueTile extends StatelessWidget {
  const _SmsIssueTile({required this.row});
  final RawMessageIssueRow row;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(row.status == 'FAILED' ? Icons.error_outline : Icons.help_outline),
        title: Text('${row.sender} · ${row.status}'),
        subtitle: Text(
          '${row.bodyPreview}\n${timeAgo(row.receivedAt)}'
          '${row.error != null ? ' · ${row.error}' : ''}',
        ),
        isThreeLine: true,
      ),
    );
  }
}
