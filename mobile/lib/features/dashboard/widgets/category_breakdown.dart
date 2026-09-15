import 'package:flutter/material.dart';

import '../../../core/money.dart';
import '../../../models/category.dart';
import '../../../models/monthly_spend.dart';

/// Where the month's money went, ranked.
///
/// The previous version had four separate problems, all of which came from
/// showing everything at once:
///
///  1. **Transfers counted as spending.** "Income & Transfers — 30% of this
///     month" sat in the ranking as if it were an expense. Money moving
///     between your own accounts nets to zero (plan invariant 7), so it is
///     now excluded from the ranking and its denominator, and shown
///     separately below with a reason. This was a correctness problem, not
///     a cosmetic one: every percentage on the screen was wrong.
///  2. **A one-bar bar chart per group.** A group with a single category
///     (Food & Drink → Restaurants) rendered a full-width bar that could
///     only ever be 100%, conveying nothing. Those collapse to one row.
///  3. **"1 transaction" under every row**, plus the count again on the
///     group line. Said twice, worth saying once.
///  4. **No hierarchy.** Group and child sat at nearly the same weight, so
///     the eye had nothing to grab. Groups now carry the bar and the
///     emphasis; children are revealed on tap.
///
/// The bar is one hue at one saturation for every row -- never darker for
/// bigger. Shading a bar by its own length double-encodes the only thing
/// the length already says, and burns the one free channel a chart has.
class CategoryBreakdown extends StatefulWidget {
  const CategoryBreakdown({
    super.key,
    required this.rows,
    required this.categories,
    required this.currency,
    this.onCategoryTap,
  });

  final List<MonthlySpend> rows;
  final List<Category> categories;
  final String currency;

  /// Tapping a leaf category opens the transaction list filtered to it
  /// (docs/APP_IMPROVEMENTS.md section 3.3).
  final void Function(String categoryId)? onCategoryTap;

  @override
  State<CategoryBreakdown> createState() => _CategoryBreakdownState();
}

class _CategoryBreakdownState extends State<CategoryBreakdown> {
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final model = _Model.from(widget.rows, widget.categories);

    if (model.spend.isEmpty && model.excluded.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'No spending this month yet.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final group in model.spend)
          _GroupRow(
            group: group,
            totalPaisa: model.spendTotalPaisa,
            currency: widget.currency,
            expanded: _expanded.contains(group.key),
            onToggle: group.isLeaf
                ? null
                : () => setState(() {
                      _expanded.contains(group.key)
                          ? _expanded.remove(group.key)
                          : _expanded.add(group.key);
                    }),
            onCategoryTap: widget.onCategoryTap,
          ),
        if (model.excluded.isNotEmpty) _ExcludedSection(model: model, currency: widget.currency),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Model

class _Leaf {
  const _Leaf({required this.id, required this.name, required this.paisa, required this.txnCount});
  final String? id;
  final String name;
  final int paisa;
  final int txnCount;
}

class _Group {
  _Group({required this.key, required this.name});
  final String key;
  final String name;
  final List<_Leaf> leaves = [];
  int paisa = 0;
  int txnCount = 0;

  /// A group with exactly one category under it *is* that category -- there
  /// is no breakdown to reveal, so it gets no expander and no child bar.
  bool get isLeaf => leaves.length <= 1;
}

class _Model {
  const _Model({
    required this.spend,
    required this.excluded,
    required this.spendTotalPaisa,
    required this.excludedTotalPaisa,
  });

  /// Real spending, ranked high to low.
  final List<_Group> spend;

  /// Categories flagged `is_spend = false` -- transfers, income, savings.
  /// Kept out of the ranking and out of its denominator.
  final List<_Group> excluded;

  final int spendTotalPaisa;
  final int excludedTotalPaisa;

  static _Model from(List<MonthlySpend> rows, List<Category> categories) {
    final byId = {for (final c in categories) c.id: c};
    final spend = <String, _Group>{};
    final excluded = <String, _Group>{};

    for (final row in rows) {
      if (row.spentPaisa <= 0) continue;

      final category = row.categoryId == null ? null : byId[row.categoryId];
      final parent = category?.parentId == null ? null : byId[category!.parentId];

      // is_spend lives on the group when there is one -- "Transfer" inherits
      // its non-spend nature from "Income & Transfers". Uncategorized rows
      // count as spend: unknown is not the same as excluded, and quietly
      // dropping them would understate the month.
      final isSpend = parent?.isSpend ?? category?.isSpend ?? true;
      final into = isSpend ? spend : excluded;

      final key = parent?.id ?? category?.id ?? '__uncategorized__';
      final name = parent?.name ?? category?.name ?? 'Uncategorized';
      final group = into.putIfAbsent(key, () => _Group(key: key, name: name));

      group.leaves.add(_Leaf(
        id: category?.id,
        name: category?.name ?? 'Uncategorized',
        paisa: row.spentPaisa,
        txnCount: row.txnCount,
      ));
      group.paisa += row.spentPaisa;
      group.txnCount += row.txnCount;
    }

    List<_Group> ranked(Map<String, _Group> m) {
      final list = m.values.toList()..sort((a, b) => b.paisa.compareTo(a.paisa));
      for (final g in list) {
        g.leaves.sort((a, b) => b.paisa.compareTo(a.paisa));
      }
      return list;
    }

    final spendList = ranked(spend);
    final excludedList = ranked(excluded);
    return _Model(
      spend: spendList,
      excluded: excludedList,
      spendTotalPaisa: spendList.fold(0, (s, g) => s + g.paisa),
      excludedTotalPaisa: excludedList.fold(0, (s, g) => s + g.paisa),
    );
  }
}

// ---------------------------------------------------------------------------
// Rows

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.group,
    required this.totalPaisa,
    required this.currency,
    required this.expanded,
    required this.onToggle,
    required this.onCategoryTap,
  });

  final _Group group;
  final int totalPaisa;
  final String currency;
  final bool expanded;
  final VoidCallback? onToggle;
  final void Function(String categoryId)? onCategoryTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final share = totalPaisa == 0 ? 0.0 : group.paisa / totalPaisa;
    final leafId = group.isLeaf && group.leaves.isNotEmpty ? group.leaves.first.id : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          // A single-category group jumps straight to its transactions;
          // a real group opens its breakdown. One tap either way.
          onTap: onToggle ?? (leafId == null ? null : () => onCategoryTap?.call(leafId)),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    if (onToggle != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: AnimatedRotation(
                          turns: expanded ? 0.25 : 0,
                          duration: const Duration(milliseconds: 150),
                          child: Icon(
                            Icons.chevron_right,
                            size: 18,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        group.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      formatPaisa(group.paisa, currency: currency),
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                _Bar(fraction: share),
                const SizedBox(height: 5),
                Text(
                  '${_pct(share)} · ${group.txnCount} txn${group.txnCount == 1 ? '' : 's'}',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 22, bottom: 6),
            child: Column(
              children: [
                for (final leaf in group.leaves)
                  _LeafRow(
                    leaf: leaf,
                    groupPaisa: group.paisa,
                    currency: currency,
                    onTap: leaf.id == null ? null : () => onCategoryTap?.call(leaf.id!),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// Under 1% renders as "<1%" rather than "0%", which would read as
  /// "nothing" next to a non-zero amount.
  static String _pct(double share) {
    final pct = share * 100;
    if (pct > 0 && pct < 1) return '<1%';
    return '${pct.round()}%';
  }
}

class _LeafRow extends StatelessWidget {
  const _LeafRow({
    required this.leaf,
    required this.groupPaisa,
    required this.currency,
    required this.onTap,
  });

  final _Leaf leaf;
  final int groupPaisa;
  final String currency;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Expanded(
              child: Text(
                leaf.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              formatPaisa(leaf.paisa, currency: currency),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Money the ranking above deliberately leaves out, with the reason.
///
/// Collapsed by default and visibly secondary: it must be *findable* --
/// silently dropping Rs 5,000 from a screen would be its own kind of lie --
/// without competing with the spending it isn't part of.
class _ExcludedSection extends StatefulWidget {
  const _ExcludedSection({required this.model, required this.currency});
  final _Model model;
  final String currency;

  @override
  State<_ExcludedSection> createState() => _ExcludedSectionState();
}

class _ExcludedSectionState extends State<_ExcludedSection> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: theme.colorScheme.outlineVariant, height: 17),
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Not counted as spending',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  Text(
                    formatPaisa(widget.model.excludedTotalPaisa, currency: widget.currency),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_open) ...[
            Padding(
              padding: const EdgeInsets.only(left: 22, bottom: 8),
              child: Text(
                'Transfers between your own accounts and money coming in. '
                'Neither is an expense, so they are left out of the totals '
                'and percentages above.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            for (final group in widget.model.excluded)
              Padding(
                padding: const EdgeInsets.only(left: 22, bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(group.name, style: theme.textTheme.bodyMedium),
                    ),
                    Text(
                      formatPaisa(group.paisa, currency: widget.currency),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// A thin bar with a rounded data-end and a square baseline, on a hairline
/// track. Rounding both ends makes a short bar read as longer than it is,
/// because the cap adds length the value didn't earn.
class _Bar extends StatelessWidget {
  const _Bar({required this.fraction});
  final double fraction;

  static const _height = 6.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: Container(
        height: _height,
        color: scheme.surfaceContainerHighest,
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          // A value too small to draw still gets a visible sliver: a bar of
          // literally zero width next to a non-zero amount reads as a bug.
          widthFactor: fraction.clamp(0.012, 1.0),
          child: Container(
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: const BorderRadius.horizontal(right: Radius.circular(_height / 2)),
            ),
          ),
        ),
      ),
    );
  }
}
