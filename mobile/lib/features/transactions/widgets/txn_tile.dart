import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/money.dart';
import '../../../models/enums.dart';
import '../../../models/transaction.dart';

/// One row of the transaction list.
///
/// Three pieces of information, in the order the eye should find them: what
/// it was, how much, and then the qualifiers. The date used to lead the
/// subtitle on every single row, which was pure repetition once the list
/// groups by day -- the day header says it once, so the row spends that
/// space on the time and the things that actually vary.
class TxnTile extends StatelessWidget {
  const TxnTile({
    super.key,
    required this.txn,
    required this.onTap,
    this.showStatusBadge = true,
  });
  final Txn txn;
  final VoidCallback onTap;

  /// False on the review queue, where every row is NEEDS_REVIEW by
  /// definition and the badge would be on all of them saying nothing.
  final bool showStatusBadge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCredit = txn.direction == Direction.credit;

    // A transfer is not spending (plan invariant 7), so it must not read
    // with the same weight as money that actually left. Muted, not hidden.
    final amountColor = txn.isTransfer
        ? theme.colorScheme.onSurfaceVariant
        : isCredit
            ? Colors.green.shade700
            : Colors.red.shade700;

    final title = txn.counterparty?.isNotEmpty == true ? txn.counterparty! : txn.descriptionRaw;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _Glyph(txn: txn),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _subtitle(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                      // Badges rather than more text in the subtitle: these
                      // are states, and a state that reads as just another
                      // comma-separated word gets skipped.
                      if (txn.entrySource == EntrySource.manual) ...[
                        const SizedBox(width: 6),
                        const _Badge('Manual'),
                      ],
                      if (showStatusBadge && txn.status == TxnStatus.needsReview) ...[
                        const SizedBox(width: 6),
                        const _Badge('Review', tone: _BadgeTone.attention),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              formatPaisaSigned(txn.amountPaisa, isCredit: isCredit, currency: txn.currency),
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: amountColor,
                // Right-aligned amounts only line up as a column with
                // tabular figures; proportional digits make every row's
                // decimal point land somewhere slightly different.
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _subtitle() {
    return [
      DateFormat.jm().format(txn.occurredAt.toLocal()),
      if (txn.isTransfer) 'Transfer' else txn.categoryName ?? 'Uncategorized',
      txn.accountDisplayName,
    ].join(' · ');
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph({required this.txn});
  final Txn txn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCredit = txn.direction == Direction.credit;
    final icon = switch (txn) {
      _ when txn.isTransfer => Icons.swap_horiz,
      _ when txn.entrySource == EntrySource.manual => Icons.edit_outlined,
      _ => isCredit ? Icons.south_west : Icons.north_east,
    };
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 17, color: theme.colorScheme.onSurfaceVariant),
    );
  }
}

enum _BadgeTone { neutral, attention }

class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.tone = _BadgeTone.neutral});
  final String text;
  final _BadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (tone) {
      _BadgeTone.neutral => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
      _BadgeTone.attention => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
              fontSize: 10,
            ),
      ),
    );
  }
}
