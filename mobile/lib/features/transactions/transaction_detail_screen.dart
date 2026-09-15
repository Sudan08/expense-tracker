import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../data/transactions_repository.dart';
import '../../models/enums.dart';
import '../dashboard/dashboard_controller.dart';
import 'filtered_transactions_controller.dart';
import 'recategorize_sheet.dart';
import 'transactions_controller.dart';

class TransactionDetailScreen extends ConsumerWidget {
  const TransactionDetailScreen({super.key, required this.transactionId});
  final String transactionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txnAsync = ref.watch(transactionByIdProvider(transactionId));

    return Scaffold(
      appBar: AppBar(title: const Text('Transaction')),
      body: txnAsync.when(
        data: (txn) {
          final isCredit = txn.direction == Direction.credit;
          // Same subtle in/out tint as the list row -- a transfer is not
          // spending, so it stays neutral rather than reading as money out.
          final amountColor = txn.isTransfer
              ? null
              : isCredit
                  ? Colors.green.shade700
                  : Colors.red.shade700;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                formatPaisaSigned(txn.amountPaisa, isCredit: isCredit, currency: txn.currency),
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(color: amountColor),
              ),
              const SizedBox(height: 4),
              Text(
                DateFormat.yMMMMd().add_jms().format(txn.occurredAt.toLocal()),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              _DetailRow('Account', txn.accountDisplayName),
              _DetailRow('Description', txn.descriptionRaw),
              if (txn.userNote != null) _DetailRow('Note', txn.userNote!),
              if (txn.counterparty != null) _DetailRow('Counterparty', txn.counterparty!),
              if (txn.channel != null) _DetailRow('Channel', txn.channel!),
              if (txn.reference != null) _DetailRow('Reference', txn.reference!),
              _DetailRow('Category', txn.isTransfer ? 'Transfer (excluded from spend)' : (txn.categoryName ?? 'Uncategorized')),
              if (txn.categorySource != null) _DetailRow('Categorized by', txn.categorySource!),
              _DetailRow('Status', _statusLabel(txn.status)),
              if (txn.balanceAfterPaisa != null)
                _MaskableDetailRow(
                  'Balance after',
                  formatPaisa(txn.balanceAfterPaisa!, currency: txn.currency),
                ),
              const SizedBox(height: 24),
              if (!txn.isTransfer)
                FilledButton.tonal(
                  onPressed: () async {
                    final changed = await showRecategorizeSheet(context, ref, txn);
                    if (changed) {
                      ref.invalidate(transactionByIdProvider(transactionId));
                      ref.invalidate(filteredTransactionsProvider);
                      ref.invalidate(reviewQueueProvider);
                      // A category change moves money between the dashboard's
                      // category bars -- without this the dashboard would
                      // show the old breakdown until monthlySpendProvider's
                      // own staleTime happened to elapse.
                      ref.invalidate(monthlySpendProvider);
                    }
                  },
                  child: Text(txn.categoryId == null ? 'Categorize' : 'Recategorize'),
                ),
              if (txn.status != TxnStatus.confirmed) ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () async {
                    await ref.read(transactionsRepositoryProvider).confirm(txn.id);
                    ref.invalidate(transactionByIdProvider(transactionId));
                    ref.invalidate(filteredTransactionsProvider);
                    ref.invalidate(reviewQueueProvider);
                  },
                  child: const Text('Confirm'),
                ),
              ],
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load transaction: $e')),
      ),
    );
  }

  String _statusLabel(TxnStatus status) => switch (status) {
        TxnStatus.needsReview => 'Needs review',
        TxnStatus.categorized => 'Categorized',
        TxnStatus.confirmed => 'Confirmed',
      };
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

/// A _DetailRow with its own eye icon, defaulting to hidden.
///
/// Used for "Balance after" specifically: that figure is a running account
/// total, not just this one transaction's amount, and it's arguably the
/// single most sensitive number on this whole screen -- it says how much
/// money is in the account, not just how much moved. Local widget state
/// rather than a shared provider like the dashboard's spentHiddenProvider:
/// nothing else on the app needs to know whether this one row is masked,
/// and resetting to hidden every time the screen opens is exactly the
/// behaviour wanted, not a limitation to work around.
class _MaskableDetailRow extends StatefulWidget {
  const _MaskableDetailRow(this.label, this.value);
  final String label;
  final String value;

  @override
  State<_MaskableDetailRow> createState() => _MaskableDetailRowState();
}

class _MaskableDetailRowState extends State<_MaskableDetailRow> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 120,
            child: Text(widget.label, style: theme.textTheme.bodySmall),
          ),
          Expanded(child: Text(_hidden ? '••••••' : widget.value)),
          IconButton(
            icon: Icon(
              _hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            tooltip: _hidden ? 'Show ${widget.label.toLowerCase()}' : 'Hide ${widget.label.toLowerCase()}',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => setState(() => _hidden = !_hidden),
          ),
        ],
      ),
    );
  }
}
