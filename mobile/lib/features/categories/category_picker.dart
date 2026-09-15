import 'package:flutter/material.dart';

import '../../models/category.dart';

/// Searchable category list, grouped under each category's parent
/// (categories.parent_id). Groups are headers, not choices -- transactions
/// and rules are always filed under a specific category. Categories with no
/// parent and no children (just "Other") are listed last.
///
/// Search matches a category's own name or its group's, so "health" lists
/// everything under Health and "med" finds Medicine & Pharmacy.
class CategoryPicker extends StatefulWidget {
  const CategoryPicker({
    super.key,
    required this.categories,
    required this.selectedId,
    required this.onSelected,
    this.enabled = true,
  });

  final List<Category> categories;
  final String? selectedId;
  final ValueChanged<String> onSelected;
  final bool enabled;

  @override
  State<CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<CategoryPicker> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groupIds = {for (final c in widget.categories) ?c.parentId};
    final groups = widget.categories.where((c) => groupIds.contains(c.id)).toList()..sort(_byName);
    final query = _query.trim().toLowerCase();
    bool matches(Category c, Category? group) =>
        query.isEmpty ||
        c.name.toLowerCase().contains(query) ||
        (group != null && group.name.toLowerCase().contains(query));

    final rows = <Widget>[];
    for (final group in groups) {
      final items = widget.categories.where((c) => c.parentId == group.id && matches(c, group)).toList()
        ..sort(_byName);
      if (items.isEmpty) continue;
      rows.add(_GroupHeader(group.name, count: items.length));
      rows.addAll(items.map((c) => _tile(c, indented: true)));
    }
    final ungrouped = widget.categories
        .where((c) => c.parentId == null && !groupIds.contains(c.id) && matches(c, null))
        .toList()
      ..sort(_byName);
    if (ungrouped.isNotEmpty) {
      if (rows.isNotEmpty) rows.add(const Divider(height: 24, indent: 16, endIndent: 16));
      rows.addAll(ungrouped.map((c) => _tile(c, indented: false)));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _search,
            enabled: widget.enabled,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search categories',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'Clear search',
                      onPressed: () => setState(() {
                        _search.clear();
                        _query = '';
                      }),
                    ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        const SizedBox(height: 4),
        Flexible(
          child: rows.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('No category matches "${_query.trim()}"'),
                )
              : ListView(shrinkWrap: true, children: rows),
        ),
      ],
    );
  }

  Widget _tile(Category c, {required bool indented}) {
    final selected = c.id == widget.selectedId;
    return Builder(builder: (context) {
      final theme = Theme.of(context);
      return ListTile(
        dense: true,
        // Indented under its group header, so the eye can see at a glance
        // which names belong together. A standalone category (no group) sits
        // at the margin, which is the honest signal that it has no parent.
        contentPadding: EdgeInsets.only(left: indented ? 32 : 16, right: 16),
        title: Text(
          c.name,
          style: selected
              ? theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                )
              : theme.textTheme.bodyLarge,
        ),
        trailing: selected ? Icon(Icons.check, color: theme.colorScheme.primary) : null,
        selected: selected,
        selectedTileColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
        onTap: widget.enabled ? () => widget.onSelected(c.id) : null,
      );
    });
  }

  static int _byName(Category a, Category b) => a.name.compareTo(b.name);
}

/// A group is a label, not a choice -- transactions are always filed under a
/// specific category. It has to read that way too, or the eye tries to tap
/// it: small, upper-case, tracked out, in the muted colour the rest of the
/// app uses for captions, with a hairline running to the edge to bind the
/// names beneath it into one block.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.name, {required this.count});
  final String name;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Row(
        children: [
          Text(
            name.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: muted,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.9,
            ),
          ),
          const SizedBox(width: 8),
          Text('$count', style: theme.textTheme.labelSmall?.copyWith(color: muted.withValues(alpha: 0.7))),
          const SizedBox(width: 10),
          Expanded(child: Divider(height: 1, color: theme.colorScheme.outlineVariant)),
        ],
      ),
    );
  }
}

/// [CategoryPicker] in its own bottom sheet, for forms that only need a
/// category field. Resolves to the picked category's id, or null if dismissed.
Future<String?> showCategoryPickerSheet(
  BuildContext context, {
  required List<Category> categories,
  required String? selectedId,
}) {
  return showModalBottomSheet<String>(
    context: context,
    // Root navigator, not the branch one. StatefulShellRoute nests each
    // branch's Navigator *inside* the shell Scaffold's body, so a sheet
    // pushed on the nearest Navigator paints under the Scaffold's own FAB
    // and bottom nav -- the Add button floated on top of the sheet and the
    // barrier dimmed only the list. A modal belongs above app chrome
    // wherever it was launched from.
    useRootNavigator: true,
    isScrollControlled: true,
    // Same fix as the recategorize sheet: without it the sheet can grow
    // behind the status bar.
    useSafeArea: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: EdgeInsets.only(top: 16, bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.85,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Choose category', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        'Grey headings are groups — pick one of the categories under them.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: CategoryPicker(
                  categories: categories,
                  selectedId: selectedId,
                  onSelected: (id) => Navigator.of(context).pop(id),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
