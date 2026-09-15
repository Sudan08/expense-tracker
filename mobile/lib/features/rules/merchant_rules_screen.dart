import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/async_value_view.dart';
import '../../data/categories_repository.dart';
import '../../data/merchant_rules_repository.dart';
import '../../models/category.dart';
import '../../models/merchant_rule.dart';
import '../categories/category_picker.dart';

/// The rules that silently decide categorisation on every sync. The phone
/// could always create these (the recategorize correction loop) but never
/// see, edit, or delete one -- a single mistapped category would
/// miscategorise that merchant forever with nothing in the app to catch it.
/// See docs/APP_IMPROVEMENTS.md section 5.1.
class MerchantRulesScreen extends ConsumerWidget {
  const MerchantRulesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(merchantRulesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Merchant rules')),
      body: RefreshIndicator(
        onRefresh: () => ref.read(merchantRulesProvider.notifier).refresh(),
        child: AsyncValueView(
          value: rules,
          data: (list) {
            if (list.isEmpty) {
              return ListView(
                children: const [
                  Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No merchant rules yet.')),
                  ),
                ],
              );
            }
            return ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _RuleTile(rule: list[i]),
            );
          },
          loading: () => ListView(children: [
            SizedBox(height: 200, child: Center(child: CircularProgressIndicator())),
          ]),
          error: (e) => Center(child: Text('Could not load rules: $e')),
        ),
      ),
    );
  }
}

class _RuleTile extends ConsumerWidget {
  const _RuleTile({required this.rule});
  final MerchantRule rule;

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this rule?'),
        content: Text(
          'Future transactions matching "${rule.pattern}" will stop being '
          'auto-categorized as ${rule.categoryName ?? 'this category'}.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(merchantRulesRepositoryProvider).delete(rule.id);
    ref.invalidate(merchantRulesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      title: Text(
        rule.counterpartyLabel ?? rule.pattern,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${rule.categoryName ?? 'Unknown category'} · pattern: ${rule.pattern}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      leading: CircleAvatar(
        child: Text('${rule.hitCount}', style: Theme.of(context).textTheme.labelSmall),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Delete rule',
        onPressed: () => _confirmDelete(context, ref),
      ),
      onTap: () async {
        final changed = await showModalBottomSheet<bool>(
          context: context,
          // Root navigator, not the branch one. StatefulShellRoute nests each
          // branch's Navigator *inside* the shell Scaffold's body, so a sheet
          // pushed on the nearest Navigator paints under the Scaffold's own FAB
          // and bottom nav -- the Add button floated on top of the sheet and the
          // barrier dimmed only the list. A modal belongs above app chrome
          // wherever it was launched from.
          useRootNavigator: true,
          isScrollControlled: true,
          builder: (context) => _EditRuleSheet(rule: rule),
        );
        if (changed == true) ref.invalidate(merchantRulesProvider);
      },
    );
  }
}

class _EditRuleSheet extends ConsumerStatefulWidget {
  const _EditRuleSheet({required this.rule});
  final MerchantRule rule;

  @override
  ConsumerState<_EditRuleSheet> createState() => _EditRuleSheetState();
}

class _EditRuleSheetState extends ConsumerState<_EditRuleSheet> {
  late final TextEditingController _pattern = TextEditingController(text: widget.rule.pattern);
  late final TextEditingController _label = TextEditingController(text: widget.rule.counterpartyLabel ?? '');
  late final TextEditingController _priority = TextEditingController(text: '${widget.rule.priority}');
  late String _categoryId = widget.rule.categoryId;
  bool _saving = false;

  @override
  void dispose() {
    _pattern.dispose();
    _label.dispose();
    _priority.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final pattern = _pattern.text.trim();
    if (pattern.isEmpty) return;
    final priority = int.tryParse(_priority.text.trim()) ?? widget.rule.priority;
    setState(() => _saving = true);
    try {
      await ref.read(merchantRulesRepositoryProvider).update(
            id: widget.rule.id,
            pattern: pattern,
            categoryId: _categoryId,
            counterpartyLabel: _label.text.trim().isEmpty ? null : _label.text.trim(),
            priority: priority,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Edit rule', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              TextField(
                controller: _pattern,
                enabled: !_saving,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Pattern (regex over description)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _label,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'Counterparty label (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _priority,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Priority (lower matches first)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              categories.when(
                data: (list) {
                  final Category? selected = list.where((c) => c.id == _categoryId).firstOrNull;
                  return InkWell(
                    onTap: _saving
                        ? null
                        : () async {
                            final id = await showCategoryPickerSheet(
                              context,
                              categories: list,
                              selectedId: _categoryId,
                            );
                            if (id != null) setState(() => _categoryId = id);
                          },
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Category',
                        border: OutlineInputBorder(),
                        suffixIcon: Icon(Icons.arrow_drop_down),
                      ),
                      child: Text(selected?.name ?? 'Choose a category'),
                    ),
                  );
                },
                loading: () => const LinearProgressIndicator(),
                error: (e, _) => Text('Could not load categories: $e'),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
