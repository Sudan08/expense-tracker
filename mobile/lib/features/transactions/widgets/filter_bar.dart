import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money.dart';
import '../../../data/accounts_repository.dart';
import '../../../data/categories_repository.dart';
import '../../../models/category.dart';
import '../../../models/enums.dart';
import '../transaction_filter.dart';

/// Search field plus a single scrolling row of filter chips.
///
/// One row, not a filter panel: the chips are the entire state of the query,
/// always visible, and each one reads as a sentence fragment ("Last 3
/// months", "Money out", "3 categories") rather than a control label. An
/// active filter you cannot see is the thing that makes a list confusing --
/// which was the complaint this screen started from.
class TransactionFilterBar extends ConsumerStatefulWidget {
  const TransactionFilterBar({super.key});

  @override
  ConsumerState<TransactionFilterBar> createState() => _TransactionFilterBarState();
}

class _TransactionFilterBarState extends ConsumerState<TransactionFilterBar> {
  late final TextEditingController _search =
      TextEditingController(text: ref.read(transactionFilterProvider).search);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _update(TransactionFilter Function(TransactionFilter) change) {
    final notifier = ref.read(transactionFilterProvider.notifier);
    notifier.state = change(notifier.state);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filter = ref.watch(transactionFilterProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search description, merchant or note',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: filter.search.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      tooltip: 'Clear search',
                      onPressed: () {
                        _search.clear();
                        _update((f) => f.copyWith(search: ''));
                      },
                    ),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) => _update((f) => f.copyWith(search: value)),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              if (!filter.isDefault) ...[
                ActionChip(
                  avatar: const Icon(Icons.close, size: 16),
                  label: const Text('Clear'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    _search.clear();
                    _update((_) => const TransactionFilter());
                  },
                ),
                const SizedBox(width: 8),
              ],
              _Chip(
                label: filter.preset.label,
                active: filter.preset != const TransactionFilter().preset,
                onTap: _pickDateRange,
              ),
              _Chip(
                label: switch (filter.direction) {
                  Direction.debit => 'Money out',
                  Direction.credit => 'Money in',
                  null => 'In & out',
                },
                active: filter.direction != null,
                onTap: _pickDirection,
              ),
              _Chip(
                label: filter.uncategorizedOnly
                    ? 'Uncategorized'
                    : switch (filter.categoryIds.length) {
                        0 => 'Category',
                        1 => '1 category',
                        final n => '$n categories',
                      },
                active: filter.categoryIds.isNotEmpty || filter.uncategorizedOnly,
                onTap: _pickCategories,
              ),
              _Chip(
                label: switch (filter.accountIds.length) {
                  0 => 'Account',
                  1 => '1 account',
                  final n => '$n accounts',
                },
                active: filter.accountIds.isNotEmpty,
                onTap: _pickAccounts,
              ),
              _Chip(
                label: filter.status == null ? 'Status' : _statusLabel(filter.status!),
                active: filter.status != null,
                onTap: _pickStatus,
              ),
              _Chip(
                label: filter.transfers.label,
                active: filter.transfers != const TransactionFilter().transfers,
                onTap: _pickTransfers,
              ),
              _Chip(
                label: _amountLabel(filter),
                active: filter.minPaisa != null || filter.maxPaisa != null,
                onTap: _pickAmount,
              ),
            ],
          ),
        ),
        Divider(height: 17, color: theme.colorScheme.outlineVariant),
      ],
    );
  }

  static String _statusLabel(TxnStatus s) => switch (s) {
        TxnStatus.needsReview => 'Needs review',
        TxnStatus.categorized => 'Categorized',
        TxnStatus.confirmed => 'Confirmed',
      };

  static String _amountLabel(TransactionFilter f) {
    if (f.minPaisa == null && f.maxPaisa == null) return 'Amount';
    final min = f.minPaisa == null ? null : formatPaisa(f.minPaisa!);
    final max = f.maxPaisa == null ? null : formatPaisa(f.maxPaisa!);
    if (min != null && max != null) return '$min – $max';
    return min != null ? 'Over $min' : 'Under $max';
  }

  // ---------------------------------------------------------------- sheets

  Future<void> _pickDateRange() async {
    final filter = ref.read(transactionFilterProvider);
    final choice = await _showOptions<DateRangePreset>(
      title: 'Date range',
      options: DateRangePreset.values.where((p) => p != DateRangePreset.custom),
      selected: filter.preset,
      labelOf: (p) => p.label,
      extra: ListTile(
        leading: const Icon(Icons.edit_calendar_outlined),
        title: const Text('Pick exact dates'),
        // Root navigator, explicitly -- this tile is built here in
        // _pickDateRange's scope, not inside _showOptions' own sheet
        // builder, so `context` is the filter bar's, which lives in the
        // branch Navigator nested inside AppShell (see the other
        // useRootNavigator notes in this file). A plain Navigator.pop(context)
        // would pop *that* Navigator instead of the sheet's -- and since the
        // branch only has one route, it would evict the whole transactions
        // screen, leaving a black hole behind the still-open sheet.
        onTap: () => Navigator.of(context, rootNavigator: true)
            .pop(const _Choice(DateRangePreset.custom)),
      ),
    );
    if (choice == null || !mounted) return;
    final picked = choice.value;

    if (picked != DateRangePreset.custom) {
      _update((f) => f.copyWith(preset: picked));
      return;
    }
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2015),
      lastDate: DateTime.now(),
      initialDateRange: filter.customFrom != null && filter.customTo != null
          ? DateTimeRange(start: filter.customFrom!, end: filter.customTo!)
          : null,
    );
    if (range == null) return;
    _update((f) => f.copyWith(
          preset: DateRangePreset.custom,
          customFrom: range.start,
          customTo: range.end,
        ));
  }

  Future<void> _pickDirection() async {
    final current = ref.read(transactionFilterProvider).direction;
    final choice = await _showOptions<Direction?>(
      title: 'Direction',
      options: const [null, Direction.debit, Direction.credit],
      selected: current,
      labelOf: (d) => switch (d) {
        null => 'Both',
        Direction.debit => 'Money out',
        Direction.credit => 'Money in',
      },
    );
    if (choice == null) return;
    _update((f) => f.copyWith(direction: choice.value));
  }

  Future<void> _pickStatus() async {
    final current = ref.read(transactionFilterProvider).status;
    final choice = await _showOptions<TxnStatus?>(
      title: 'Status',
      options: const [null, ...TxnStatus.values],
      selected: current,
      labelOf: (s) => s == null ? 'Any status' : _statusLabel(s),
    );
    if (choice == null) return;
    _update((f) => f.copyWith(status: choice.value));
  }

  Future<void> _pickTransfers() async {
    final current = ref.read(transactionFilterProvider).transfers;
    final choice = await _showOptions<TransferMode>(
      title: 'Transfers',
      subtitle: 'Money moving between your own accounts nets to zero, so it '
          'is never counted in the totals below — this only controls whether '
          'you see the rows.',
      options: TransferMode.values,
      selected: current,
      labelOf: (m) => m.label,
    );
    if (choice == null) return;
    _update((f) => f.copyWith(transfers: choice.value));
  }

  Future<void> _pickCategories() async {
    final categories = ref.read(categoriesProvider).valueOrNull ?? const <Category>[];
    final filter = ref.read(transactionFilterProvider);
    final result = await showModalBottomSheet<_CategorySelection>(
      context: context,
      // Root navigator, not the branch one. StatefulShellRoute nests each
      // branch's Navigator *inside* the shell Scaffold's body, so a sheet
      // pushed on the nearest Navigator paints under the Scaffold's own FAB
      // and bottom nav -- the Add button floated on top of the sheet and the
      // barrier dimmed only the list. A modal belongs above app chrome
      // wherever it was launched from.
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _CategoryFilterSheet(
        categories: categories,
        selected: filter.categoryIds,
        uncategorizedOnly: filter.uncategorizedOnly,
      ),
    );
    if (result == null) return;
    _update((f) => f.copyWith(
          categoryIds: result.ids,
          uncategorizedOnly: result.uncategorizedOnly,
        ));
  }

  Future<void> _pickAccounts() async {
    final accounts = ref.read(accountsProvider).valueOrNull ?? const [];
    final selected = {...ref.read(transactionFilterProvider).accountIds};
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _SheetTitle('Accounts'),
              for (final a in accounts)
                CheckboxListTile(
                  dense: true,
                  value: selected.contains(a.id),
                  title: Text(a.displayName),
                  onChanged: (on) => setSheetState(() {
                    on == true ? selected.add(a.id) : selected.remove(a.id);
                  }),
                ),
              _SheetActions(
                onClear: () => Navigator.pop(context, <String>{}),
                onApply: () => Navigator.pop(context, selected),
              ),
            ],
          ),
        ),
      ),
    );
    if (result == null) return;
    _update((f) => f.copyWith(accountIds: result));
  }

  Future<void> _pickAmount() async {
    final filter = ref.read(transactionFilterProvider);
    final min = TextEditingController(
        text: filter.minPaisa == null ? '' : paisaToEditableRupees(filter.minPaisa!));
    final max = TextEditingController(
        text: filter.maxPaisa == null ? '' : paisaToEditableRupees(filter.maxPaisa!));

    final applied = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _SheetTitle('Amount'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: min,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'At least',
                          prefixText: 'Rs. ',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: max,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'At most',
                          prefixText: 'Rs. ',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _SheetActions(
                onClear: () => Navigator.pop(context, false),
                onApply: () => Navigator.pop(context, true),
              ),
            ],
          ),
        ),
      ),
    );
    if (applied == null) return;
    _update((f) => f.copyWith(
          minPaisa: applied ? parsePaisa(min.text) : null,
          maxPaisa: applied ? parsePaisa(max.text) : null,
        ));
    min.dispose();
    max.dispose();
  }

  /// Show a single-choice sheet.
  ///
  /// Returns null when the sheet was dismissed, and a [_Choice] when the
  /// user actually picked something. The wrapper is load-bearing: several of
  /// these lists offer `null` as a real option ("Both", "Any status"), so a
  /// bare nullable return could not tell "they chose Any" from "they swiped
  /// the sheet away" -- and the copyWith setters below treat those two
  /// completely differently.
  Future<_Choice<T>?> _showOptions<T>({
    required String title,
    String? subtitle,
    required Iterable<T> options,
    required T selected,
    required String Function(T) labelOf,
    Widget? extra,
  }) {
    return showModalBottomSheet<_Choice<T>>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetTitle(title, subtitle: subtitle),
            RadioGroup<T>(
              groupValue: selected,
              // `value is T` rather than `value as T`: for a nullable T a
              // null is a legitimate choice, and for a non-nullable one it
              // never arrives -- this covers both without a cast that can
              // throw.
              onChanged: (value) {
                if (value is T) Navigator.pop(context, _Choice<T>(value));
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final option in options)
                    RadioListTile<T>(
                      dense: true,
                      value: option,
                      title: Text(labelOf(option)),
                    ),
                ],
              ),
            ),
            ?extra,
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// A deliberate selection, as opposed to a dismissed sheet. See _showOptions.
class _Choice<T> {
  const _Choice(this.value);
  final T value;
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.active, required this.onTap});
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: active,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        labelStyle: theme.textTheme.labelLarge?.copyWith(
          color: active ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onSurfaceVariant,
        ),
        avatar: Icon(
          Icons.expand_more,
          size: 16,
          color: active ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onSurfaceVariant,
        ),
        onSelected: (_) => onTap(),
      ),
    );
  }
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.title, {this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class _SheetActions extends StatelessWidget {
  const _SheetActions({required this.onClear, required this.onApply});
  final VoidCallback onClear;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          TextButton(onPressed: onClear, child: const Text('Clear')),
          const Spacer(),
          FilledButton(onPressed: onApply, child: const Text('Apply')),
        ],
      ),
    );
  }
}

class _CategorySelection {
  const _CategorySelection(this.ids, this.uncategorizedOnly);
  final Set<String> ids;
  final bool uncategorizedOnly;
}

/// Multi-select over the grouped category tree, plus the "Uncategorized"
/// pseudo-option. That one is not a category id and cannot travel in the
/// same set -- see TransactionFilter.uncategorizedOnly -- but it is the most
/// useful thing on this sheet, so it sits at the top rather than being
/// hidden behind a different control.
class _CategoryFilterSheet extends StatefulWidget {
  const _CategoryFilterSheet({
    required this.categories,
    required this.selected,
    required this.uncategorizedOnly,
  });
  final List<Category> categories;
  final Set<String> selected;
  final bool uncategorizedOnly;

  @override
  State<_CategoryFilterSheet> createState() => _CategoryFilterSheetState();
}

class _CategoryFilterSheetState extends State<_CategoryFilterSheet> {
  late final Set<String> _selected = {...widget.selected};
  late bool _uncategorized = widget.uncategorizedOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groupIds = {for (final c in widget.categories) ?c.parentId};
    final groups = widget.categories.where((c) => groupIds.contains(c.id)).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final ungrouped = widget.categories
        .where((c) => c.parentId == null && !groupIds.contains(c.id))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: Column(
        children: [
          const _SheetTitle('Categories'),
          Expanded(
            child: ListView(
              children: [
                SwitchListTile(
                  dense: true,
                  value: _uncategorized,
                  title: const Text('Uncategorized only'),
                  subtitle: const Text('Everything the pipeline could not file'),
                  onChanged: (on) => setState(() {
                    _uncategorized = on;
                    // The two are mutually exclusive: "no category" and
                    // "these categories" cannot both be true of one row.
                    if (on) _selected.clear();
                  }),
                ),
                const Divider(height: 1),
                for (final group in groups) ...[
                  _GroupSelectHeader(
                    name: group.name,
                    children: widget.categories.where((c) => c.parentId == group.id).toList(),
                    selected: _selected,
                    enabled: !_uncategorized,
                    onToggleAll: (ids, on) => setState(() {
                      on ? _selected.addAll(ids) : _selected.removeAll(ids);
                    }),
                  ),
                  for (final c in widget.categories.where((c) => c.parentId == group.id).toList()
                    ..sort((a, b) => a.name.compareTo(b.name)))
                    CheckboxListTile(
                      dense: true,
                      enabled: !_uncategorized,
                      value: _selected.contains(c.id),
                      title: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Text(c.name),
                      ),
                      onChanged: (on) => setState(() {
                        on == true ? _selected.add(c.id) : _selected.remove(c.id);
                      }),
                    ),
                ],
                for (final c in ungrouped)
                  CheckboxListTile(
                    dense: true,
                    enabled: !_uncategorized,
                    value: _selected.contains(c.id),
                    title: Text(c.name),
                    onChanged: (on) => setState(() {
                      on == true ? _selected.add(c.id) : _selected.remove(c.id);
                    }),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          _SheetActions(
            onClear: () => Navigator.pop(context, const _CategorySelection({}, false)),
            onApply: () => Navigator.pop(context, _CategorySelection(_selected, _uncategorized)),
          ),
        ],
      ),
    );
  }
}

class _GroupSelectHeader extends StatelessWidget {
  const _GroupSelectHeader({
    required this.name,
    required this.children,
    required this.selected,
    required this.enabled,
    required this.onToggleAll,
  });
  final String name;
  final List<Category> children;
  final Set<String> selected;
  final bool enabled;
  final void Function(Iterable<String> ids, bool on) onToggleAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ids = children.map((c) => c.id).toList();
    final allOn = ids.isNotEmpty && ids.every(selected.contains);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.9,
              ),
            ),
          ),
          TextButton(
            onPressed: enabled ? () => onToggleAll(ids, !allOn) : null,
            child: Text(allOn ? 'None' : 'All'),
          ),
        ],
      ),
    );
  }
}
