import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:go_router/go_router.dart';

import '../../core/cache/async_value_view.dart';
import '../../core/money.dart';
import '../../core/time_ago.dart';
import '../../data/categories_repository.dart';
import '../../data/data_health_repository.dart';
import '../transactions/transaction_filter.dart';
import '../../data/sync_repository.dart';
import 'daily_spend_controller.dart';
import 'dashboard_controller.dart';
import 'widgets/category_breakdown.dart';
import 'widgets/spend_heatmap.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  void _changeMonth(WidgetRef ref, DateTime month, int delta) {
    ref.read(selectedMonthProvider.notifier).state = DateTime(month.year, month.month + delta);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(selectedMonthProvider);
    final spend = ref.watch(primaryCurrencySpendProvider);
    final foreignSpend = ref.watch(foreignCurrencySpendProvider);
    final totals = ref.watch(monthTotalsProvider);
    final lastRun = ref.watch(lastSyncRunProvider);
    final isCurrentMonth = ref.watch(isCurrentMonthProvider);
    final categories = ref.watch(categoriesProvider);
    final gaps = ref.watch(openLedgerGapsProvider).valueOrNull ?? const [];

    return RefreshIndicator(
      onRefresh: () => Future.wait([
        ref.read(monthlySpendProvider.notifier).refresh(),
        ref.read(dailySpendProvider.notifier).refresh(),
        ref.read(lastSyncRunProvider.notifier).refresh(),
      ]),
      // Swipe left/right anywhere on the dashboard to change month, same
      // bound as the chevrons (no swiping past the current month). Lives on
      // a GestureDetector wrapping the whole scroll view rather than a
      // PageView -- a PageView would need to know the full month range up
      // front, and horizontal drag composes fine with ListView's vertical
      // scroll since they're different axes.
      child: GestureDetector(
        onHorizontalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity < -200) {
            if (!isCurrentMonth) _changeMonth(ref, month, 1);
          } else if (velocity > 200) {
            _changeMonth(ref, month, -1);
          }
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _LastSyncedBanner(lastRun: lastRun),
            // An open gap means these totals are known to be incomplete, so
            // it belongs above them rather than three taps away under Data
            // health. This is also where the 22:00 reminder sends you.
            if (gaps.isNotEmpty) ...[
              const SizedBox(height: 12),
              _GapCallout(count: gaps.length),
            ],
            const SizedBox(height: 16),
            _MonthSelector(month: month, isCurrentMonth: isCurrentMonth),
            const SizedBox(height: 12),
            AsyncValueView(
              value: totals,
              data: (t) => _TotalsRow(spentPaisa: t.spentPaisa, receivedPaisa: t.receivedPaisa),
              loading: () => const _TotalsRowSkeleton(),
              error: (e) => Text('Could not load totals: $e'),
            ),
            AsyncValueView(
              value: foreignSpend,
              data: (rows) => rows.isEmpty ? const SizedBox.shrink() : _ForeignCurrencyNote(rows: rows),
              loading: () => const SizedBox.shrink(),
              error: (_) => const SizedBox.shrink(),
            ),
            const SizedBox(height: 28),
            Text('Spend activity', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'One square per day, over the last year. Tap a day to see what happened.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            const SpendHeatmap(),
            const SizedBox(height: 28),
            Text('Where it went', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Tap a group to break it down, or a category to see its transactions.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            AsyncValueView(
              value: spend,
              data: (rows) => CategoryBreakdown(
                rows: rows,
                // Falls back to a flat list if the category tree hasn't
                // loaded yet: every row lands in its own group, which is
                // exactly the old behaviour rather than an empty screen.
                categories: categories.valueOrNull ?? const [],
                currency: primaryCurrency,
                onCategoryTap: (categoryId) {
                  // Hand the transaction list the same month this card is
                  // showing, not just the category -- landing on "Groceries,
                  // last 3 months" after tapping a September figure would
                  // answer a question nobody asked.
                  ref.read(transactionFilterProvider.notifier).state = TransactionFilter(
                    categoryIds: {categoryId},
                    preset: DateRangePreset.custom,
                    customFrom: DateTime(month.year, month.month),
                    customTo: DateTime(month.year, month.month + 1, 0),
                  );
                  context.go('/transactions');
                },
              ),
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e) => Text('Could not load category breakdown: $e'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthSelector extends ConsumerWidget {
  const _MonthSelector({required this.month, required this.isCurrentMonth});
  final DateTime month;
  final bool isCurrentMonth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          tooltip: 'Previous month',
          onPressed: () => ref.read(selectedMonthProvider.notifier).state =
              DateTime(month.year, month.month - 1),
        ),
        Expanded(
          child: Center(
            child: Text(DateFormat.yMMMM().format(month), style: Theme.of(context).textTheme.titleLarge),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          tooltip: 'Next month',
          // Disabled rather than clamped-and-silent: a disabled arrow says
          // "there's nothing after this" plainly, where a tap that goes
          // nowhere would just look broken.
          onPressed: isCurrentMonth
              ? null
              : () => ref.read(selectedMonthProvider.notifier).state =
                  DateTime(month.year, month.month + 1),
        ),
      ],
    );
  }
}

class _ForeignCurrencyNote extends StatelessWidget {
  const _ForeignCurrencyNote({required this.rows});
  final List rows;

  @override
  Widget build(BuildContext context) {
    // Never combined into one number -- these are different currencies with
    // no conversion rate available anywhere in this pipeline. Listed
    // separately so nothing is silently dropped from view.
    final parts = rows
        .where((r) => r.spentPaisa > 0)
        .map((r) => formatPaisa(r.spentPaisa as int, currency: r.currency as String))
        .join(', ');
    if (parts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        'Also spent this month: $parts (not included in the total above)',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _LastSyncedBanner extends StatelessWidget {
  const _LastSyncedBanner({required this.lastRun});
  final AsyncValue lastRun;

  @override
  Widget build(BuildContext context) {
    return AsyncValueView(
      value: lastRun,
      data: (run) {
        if (run == null) {
          return const _Banner(text: 'No sync has run yet.', icon: Icons.info_outline);
        }
        final completedAt = run.completedAt;
        final failed = run.error != null;
        final text = failed
            ? 'Last sync ${timeAgo(completedAt)} failed: ${run.error}'
            : 'Last synced ${timeAgo(completedAt)} · ${run.txnsInserted} new';
        return _Banner(
          text: text,
          icon: failed ? Icons.error_outline : Icons.cloud_done_outlined,
          isError: failed,
        );
      },
      loading: () => const SizedBox(height: 32),
      error: (e) => _Banner(text: 'Could not check sync status: $e', icon: Icons.error_outline, isError: true),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.icon, this.isError = false});
  final String text;
  final IconData icon;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color))),
      ],
    );
  }
}

class _TotalsRow extends StatelessWidget {
  const _TotalsRow({required this.spentPaisa, required this.receivedPaisa});
  final int spentPaisa;
  final int receivedPaisa;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _TotalCard(
            label: 'Spent',
            paisa: spentPaisa,
            color: Theme.of(context).colorScheme.errorContainer,
            onColor: Theme.of(context).colorScheme.onErrorContainer,
            hiddenProvider: spentHiddenProvider,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _TotalCard(
            label: 'Received',
            paisa: receivedPaisa,
            color: Theme.of(context).colorScheme.primaryContainer,
            onColor: Theme.of(context).colorScheme.onPrimaryContainer,
            hiddenProvider: receivedHiddenProvider,
          ),
        ),
      ],
    );
  }
}

class _TotalsRowSkeleton extends StatelessWidget {
  const _TotalsRowSkeleton();
  @override
  Widget build(BuildContext context) => const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
}

/// The month's headline figure, with its own eye icon.
///
/// Two things changed here and they are independent: the amount is no longer
/// masked *by default* (see spentHiddenProvider), and the category breakdown
/// below no longer follows this toggle at all. Hiding one headline number
/// while the bars underneath spell out every component of it was never
/// actually hiding anything -- so the toggle now covers exactly the figure
/// on the card, which is a promise it can keep.
class _TotalCard extends ConsumerWidget {
  const _TotalCard({
    required this.label,
    required this.paisa,
    required this.color,
    required this.onColor,
    required this.hiddenProvider,
  });
  final String label;
  final int paisa;
  final Color color;
  final Color onColor;
  final StateProvider<bool> hiddenProvider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hidden = ref.watch(hiddenProvider);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 14),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: onColor.withValues(alpha: 0.75),
                  ),
                ),
              ),
              IconButton(
                icon: Icon(
                  hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 18,
                  color: onColor.withValues(alpha: 0.7),
                ),
                tooltip: hidden ? 'Show $label' : 'Hide $label',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => ref.read(hiddenProvider.notifier).state = !hidden,
              ),
            ],
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              hidden ? '••••••' : formatPaisa(paisa),
              style: theme.textTheme.titleLarge?.copyWith(
                color: onColor,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Your totals are missing money, and here is the way to fix it." Sized and
/// coloured as a prompt rather than an error: a gap is normal in a
/// once-a-day pipeline (plan section 7.3), and something the user can
/// actually resolve in about a minute with their bank app open.
class _GapCallout extends StatelessWidget {
  const _GapCallout({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.tertiaryContainer,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/data-health'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              Icon(Icons.help_outline, size: 18, color: theme.colorScheme.onTertiaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  count == 1
                      ? 'One transaction is missing from these totals.'
                      : '$count transactions are missing from these totals.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
              ),
              Text(
                'Fill in',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: theme.colorScheme.onTertiaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}
