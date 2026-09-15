import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import 'filtered_transactions_controller.dart';
import 'transaction_filter.dart';
import 'widgets/filter_bar.dart';
import 'widgets/txn_tile.dart';

/// The transaction list.
///
/// The structural thesis, in priority order: **what am I looking at** (the
/// filter chips and the summary line), **when did it happen** (day headers),
/// **what was it** (the rows). The old screen had only the third of those --
/// an unbroken run of tiles with no filters, no search, no totals and a
/// silent 100-row ceiling, which is why it was hard to tell what was going
/// on. See docs/APP_IMPROVEMENTS.md sections 2.2 and 2.3.
class TransactionListScreen extends ConsumerStatefulWidget {
  const TransactionListScreen({super.key});

  @override
  ConsumerState<TransactionListScreen> createState() => _TransactionListScreenState();
}

class _TransactionListScreenState extends ConsumerState<TransactionListScreen> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeLoadMore);
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    // Fire a screen early so the next page is usually already there by the
    // time the user reaches the bottom. loadMore() is a no-op when a request
    // is already in flight, so calling it on every scroll frame is safe.
    final remaining = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 600) {
      ref.read(filteredTransactionsProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(filteredTransactionsProvider);
    final sections = ref.watch(transactionDaySectionsProvider);
    final filter = ref.watch(transactionFilterProvider);
    final loaded = async.valueOrNull;

    return Column(
      children: [
        const TransactionFilterBar(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.read(filteredTransactionsProvider.notifier).refresh(),
            // Only the very first load with nothing cached shows a spinner;
            // refresh() keeps the previous value, so the list never blanks
            // out under a pull-to-refresh.
            child: loaded == null
                ? _FullScreen(
                    child: async.hasError
                        ? Text('Could not load transactions: ${async.error}')
                        : const CircularProgressIndicator(),
                  )
                : loaded.rows.isEmpty
                    ? _EmptyState(filter: filter)
                    : _List(
                        scroll: _scroll,
                        sections: sections,
                        loaded: loaded,
                        filter: filter,
                      ),
          ),
        ),
      ],
    );
  }
}

class _List extends StatelessWidget {
  const _List({
    required this.scroll,
    required this.sections,
    required this.loaded,
    required this.filter,
  });

  final ScrollController scroll;
  final List<TxnDaySection> sections;
  final FilteredTransactions loaded;
  final TransactionFilter filter;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: scroll,
      slivers: [
        SliverToBoxAdapter(child: _SummaryBar(loaded: loaded, filter: filter)),
        for (final section in sections)
          SliverMainAxisGroup(
            slivers: [
              // Pinned, so the day you are reading is always named even
              // halfway down a long one. This is the single change that
              // makes a long list scannable.
              SliverPersistentHeader(
                pinned: true,
                delegate: _DayHeaderDelegate(section: section),
              ),
              SliverList.builder(
                itemCount: section.rows.length,
                itemBuilder: (context, i) {
                  final txn = section.rows[i];
                  return TxnTile(
                    txn: txn,
                    onTap: () => context.push('/transactions/${txn.id}'),
                  );
                },
              ),
            ],
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: loaded.loadingMore
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : loaded.hasMore
                      ? const SizedBox.shrink()
                      : Text(
                          'End of results',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                        ),
            ),
          ),
        ),
      ],
    );
  }
}

/// What the current filter actually adds up to.
///
/// Counts and totals cover the rows *loaded so far*, and the label says so
/// rather than implying a complete figure -- there is no count query behind
/// this, and a number that silently meant "the first 50" would be worse than
/// no number at all.
class _SummaryBar extends StatelessWidget {
  const _SummaryBar({required this.loaded, required this.filter});
  final FilteredTransactions loaded;
  final TransactionFilter filter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = loaded.rows.length;
    final scope = loaded.hasMore ? 'First $n' : '$n transaction${n == 1 ? '' : 's'}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$scope · ${filter.preset.label.toLowerCase()}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          _Total(label: 'out', paisa: loaded.outPaisa, color: theme.colorScheme.error),
          const SizedBox(width: 12),
          _Total(label: 'in', paisa: loaded.inPaisa, color: Colors.green.shade700),
        ],
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.paisa, required this.color});
  final String label;
  final int paisa;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          formatPaisa(paisa),
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 3),
        Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _DayHeaderDelegate extends SliverPersistentHeaderDelegate {
  _DayHeaderDelegate({required this.section});
  final TxnDaySection section;

  static const _height = 34.0;

  @override
  double get minExtent => _height;
  @override
  double get maxExtent => _height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final theme = Theme.of(context);
    final net = section.netPaisa;
    return Container(
      height: _height,
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Expanded(
            child: Text(
              _label(section.day),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (net != 0)
            Text(
              formatPaisaSigned(net.abs(), isCredit: net > 0),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }

  /// "Today" and "Yesterday" beat a date for the two days you actually think
  /// about in those terms; everything older gets the date it needs.
  static String _label(DateTime day) {
    const kathmandu = Duration(hours: 5, minutes: 45);
    final nowK = DateTime.now().toUtc().add(kathmandu);
    final today = DateTime(nowK.year, nowK.month, nowK.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return DateFormat('EEEE').format(day);
    if (day.year == today.year) return DateFormat('EEE d MMM').format(day);
    return DateFormat('EEE d MMM yyyy').format(day);
  }

  @override
  bool shouldRebuild(_DayHeaderDelegate old) => old.section != section;
}

/// Distinguishes "you have no transactions" from "nothing matches these
/// filters", which are completely different problems and used to render
/// identically.
class _EmptyState extends ConsumerWidget {
  const _EmptyState({required this.filter});
  final TransactionFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final filtered = !filter.isDefault;

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 64, 32, 32),
          child: Column(
            children: [
              Icon(
                filtered ? Icons.filter_alt_off_outlined : Icons.receipt_long_outlined,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                filtered ? 'Nothing matches these filters' : 'No transactions yet',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                filtered
                    ? '${filter.activeCount} filter${filter.activeCount == 1 ? '' : 's'} '
                        'are narrowing this list.'
                    : 'The worker adds them on its next sync. You can also add '
                        'one yourself with the Add button.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              if (filtered) ...[
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: () =>
                      ref.read(transactionFilterProvider.notifier).state = const TransactionFilter(),
                  child: const Text('Clear filters'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _FullScreen extends StatelessWidget {
  const _FullScreen({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ListView(
        children: [
          SizedBox(
            height: 240,
            child: Center(
              child: Padding(padding: const EdgeInsets.all(24), child: child),
            ),
          ),
        ],
      );
}
