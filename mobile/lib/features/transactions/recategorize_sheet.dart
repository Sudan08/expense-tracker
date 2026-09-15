import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/categories_repository.dart';
import '../../data/transactions_repository.dart';
import '../../models/transaction.dart';
import '../categories/category_picker.dart';

/// Shows the category picker plus a free-text note, and on save writes the
/// recategorize (transactions.category_id, transactions.user_note) and the
/// learned merchant_rules row -- see TransactionsRepository docs for why the
/// rule write happens alongside (plan section 10's correction loop).
Future<bool> showRecategorizeSheet(BuildContext context, WidgetRef ref, Txn txn) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    // Root navigator, not the branch one. StatefulShellRoute nests each
    // branch's Navigator *inside* the shell Scaffold's body, so a sheet
    // pushed on the nearest Navigator paints under the Scaffold's own FAB
    // and bottom nav -- the Add button floated on top of the sheet and the
    // barrier dimmed only the list. A modal belongs above app chrome
    // wherever it was launched from.
    useRootNavigator: true,
    isScrollControlled: true,
    // Without this the sheet is free to grow behind the status bar, which is
    // exactly what it did: the "Recategorize" title rendered on top of the
    // clock. useSafeArea insets the whole sheet instead of relying on the
    // content to stay short enough.
    useSafeArea: true,
    builder: (context) => _RecategorizeSheet(txn: txn),
  );
  return result ?? false;
}

class _RecategorizeSheet extends ConsumerStatefulWidget {
  const _RecategorizeSheet({required this.txn});
  final Txn txn;

  @override
  ConsumerState<_RecategorizeSheet> createState() => _RecategorizeSheetState();
}

class _RecategorizeSheetState extends ConsumerState<_RecategorizeSheet> {
  late final TextEditingController _note = TextEditingController(text: widget.txn.userNote ?? '');
  late String? _selectedCategoryId = widget.txn.categoryId;
  bool _saving = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final categoryId = _selectedCategoryId;
    if (categoryId == null) return;
    setState(() => _saving = true);
    final repo = ref.read(transactionsRepositoryProvider);
    // Only teach a merchant rule when the category actually moved. Saving a
    // note without changing the category shouldn't pile up duplicate rules
    // that all say the same thing.
    final categoryChanged = categoryId != widget.txn.categoryId;
    try {
      await Future(() async {
        await repo.recategorize(
          transactionId: widget.txn.id,
          categoryId: categoryId,
          note: _note.text,
        );
        if (categoryChanged) {
          await repo.learnMerchantRule(
            descriptionRaw: widget.txn.descriptionRaw,
            categoryId: categoryId,
            counterpartyLabel: widget.txn.counterparty,
          );
        }
      }).timeout(const Duration(seconds: 15));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      final message = e is TimeoutException ? 'Timed out talking to the server' : 'Could not save: $e';
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider);
    return SafeArea(
      child: Padding(
        // Lift the sheet above the keyboard while the note field has focus.
        // With the note now at the bottom this matters more than it did:
        // the field being typed into is the one closest to the keyboard.
        padding: EdgeInsets.only(
          top: 8,
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SizedBox(
          // Open tall rather than sizing to content. The list underneath is
          // ~50 categories, so a sheet that hugged its content was always
          // going to fill the screen anyway -- the only thing MainAxisSize.min
          // bought was an unpredictable height on a filtered search, and a
          // couple of visible rows when it did shrink.
          height: MediaQuery.sizeOf(context).height * 0.85,
          child: Column(
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Recategorize', style: Theme.of(context).textTheme.titleMedium),
                ),
              ),
              const SizedBox(height: 12),
              // The category is the decision this sheet exists for, so it
              // gets the space and the top position. The note was previously
              // above it, which put an optional field between the user and
              // the thing they opened the sheet to do.
              Expanded(
                child: categories.when(
                  data: (list) => CategoryPicker(
                    categories: list,
                    selectedId: _selectedCategoryId,
                    enabled: !_saving,
                    onSelected: (id) => setState(() => _selectedCategoryId = id),
                  ),
                  loading: () => const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Could not load categories: $e'),
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: TextField(
                  controller: _note,
                  enabled: !_saving,
                  maxLength: 500,
                  maxLines: 2,
                  minLines: 1,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Note',
                    hintText: 'What was this for?',
                    border: OutlineInputBorder(),
                    isDense: true,
                    // The 0/500 counter under an optional field is noise for
                    // the 499 characters nobody is near; maxLength still
                    // enforces the column's own check constraint.
                    counterText: '',
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: (_saving || _selectedCategoryId == null) ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
