import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../data/accounts_repository.dart';
import '../../data/categories_repository.dart';
import '../../data/data_health_repository.dart';
import '../../data/manual_entry_repository.dart';
import '../../models/account.dart';
import '../../models/category.dart';
import '../../models/data_health.dart';
import '../../models/enums.dart';
import '../../models/manual_entry.dart';
import '../categories/category_picker.dart';
import '../dashboard/daily_spend_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../transactions/filtered_transactions_controller.dart';
import '../transactions/transactions_controller.dart';

/// Record a transaction by hand.
///
/// Two modes, one form, because the fields are the same and only the
/// constraints differ:
///
///  * **Free-standing** ([gap] is null) -- a cash spend, or anything from an
///    account that sends no message. No balance is recorded, deliberately:
///    see ManualEntryDraft.balanceAfterPaisa.
///  * **Filling a gap** ([gap] is set) -- the reconciler found money moving
///    with no transaction to explain it (plan section 7.3), and this is the
///    user reading their bank app and saying what it was. The account is
///    fixed, the amount and direction are pre-filled from the gap's own
///    arithmetic, the timestamp is clamped inside the window, and a balance
///    IS recorded -- that last part is what actually closes the chain.
class ManualEntryScreen extends ConsumerStatefulWidget {
  const ManualEntryScreen({super.key, this.gap});

  final LedgerGapRow? gap;

  @override
  ConsumerState<ManualEntryScreen> createState() => _ManualEntryScreenState();
}

class _ManualEntryScreenState extends ConsumerState<ManualEntryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _description = TextEditingController();
  final _note = TextEditingController();

  String? _accountId;
  String? _categoryId;
  late Direction _direction;
  late DateTime _occurredAt;
  bool _saving = false;

  LedgerGapRow? get _gap => widget.gap;
  bool get _isGapFill => _gap != null;

  @override
  void initState() {
    super.initState();
    final gap = _gap;
    if (gap != null) {
      _accountId = gap.accountId;
      _direction = gap.missingDirection;
      _amount.text = paisaToEditableRupees(gap.missingAmountPaisa);
      _occurredAt = _midpoint(gap);
    } else {
      _direction = Direction.debit;
      _occurredAt = DateTime.now();
    }
  }

  /// Halfway between the two transactions bracketing the gap. Any instant
  /// strictly inside the window would order the entry into the chain
  /// correctly; the midpoint is the one that claims the least -- it is
  /// visibly a placeholder rather than a precise-looking time nobody
  /// verified.
  static DateTime _midpoint(LedgerGapRow gap) {
    final span = gap.beforeOccurredAt.difference(gap.afterOccurredAt);
    return gap.afterOccurredAt.add(span ~/ 2).toLocal();
  }

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    _note.dispose();
    super.dispose();
  }

  int? get _amountPaisa => parsePaisa(_amount.text);

  /// Signed, in the gap's own terms: what is still unexplained after this
  /// entry. Zero means the chain closes and the gap is genuinely answered.
  int? get _remainderPaisa {
    final gap = _gap;
    final paisa = _amountPaisa;
    if (gap == null || paisa == null) return null;
    final signed = _direction == Direction.credit ? paisa : -paisa;
    return gap.missingPaisa - signed;
  }

  /// The balance this entry leaves behind, chained forward from the balance
  /// the bank reported before the gap. Null for a free-standing entry --
  /// reconcile.py skips rows with no balance, which is exactly right for a
  /// transaction the bank never counted.
  int? get _balanceAfterPaisa {
    final gap = _gap;
    final paisa = _amountPaisa;
    if (gap == null || paisa == null) return null;
    final base = gap.afterBalancePaisa;
    if (base == null) return null;
    return base + (_direction == Direction.credit ? paisa : -paisa);
  }

  Future<void> _pickDateTime() async {
    final gap = _gap;
    // Inside a gap the timestamp is not a free choice: the reconciler orders
    // by occurred_at, so an entry outside the window is not part of the
    // chain and would leave the gap open while looking filled. One second
    // of clearance on each side keeps it strictly between.
    final first = gap == null ? DateTime(2015) : gap.afterOccurredAt.toLocal().add(const Duration(seconds: 1));
    final last = gap == null ? DateTime.now() : gap.beforeOccurredAt.toLocal().subtract(const Duration(seconds: 1));

    final date = await showDatePicker(
      context: context,
      initialDate: _occurredAt,
      firstDate: first,
      lastDate: last.isBefore(first) ? first : last,
      helpText: _isGapFill ? 'Date inside the gap' : 'Date of the transaction',
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_occurredAt),
      helpText: 'Time of the transaction',
    );
    if (!mounted) return;

    var picked = DateTime(
      date.year,
      date.month,
      date.day,
      time?.hour ?? _occurredAt.hour,
      time?.minute ?? _occurredAt.minute,
    );
    // The date picker can only constrain the day, so a time on the boundary
    // day can still land outside the window. Clamp rather than reject: the
    // user asked for "around then", and the exact second is not something
    // they know anyway.
    if (picked.isBefore(first)) picked = first;
    if (picked.isAfter(last)) picked = last;

    setState(() => _occurredAt = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final accountId = _accountId;
    if (accountId == null) return;

    final gap = _gap;
    final remainder = _remainderPaisa;

    setState(() => _saving = true);
    try {
      final draft = ManualEntryDraft(
        accountId: accountId,
        occurredAt: _occurredAt,
        direction: _direction,
        amountPaisa: _amountPaisa!,
        description: _description.text,
        currency: gap?.currency ?? primaryCurrency,
        balanceAfterPaisa: _balanceAfterPaisa,
        categoryId: _categoryId,
        note: _note.text,
        gapId: gap?.id,
      );
      await ref.read(manualEntryRepositoryProvider).record(draft);

      // Everything that counts money or lists transactions is now wrong.
      // monthlySpendProvider is invalidated rather than refreshed: a
      // gap-fill entry's occurred_at sits inside the gap's own window, which
      // can be a past month, not necessarily the one currently on screen --
      // refresh() only re-checks that one. Invalidating wipes the whole
      // per-month cache so any month opened next re-fetches for real.
      ref.invalidate(monthlySpendProvider);
      ref.read(dailySpendProvider.notifier).refresh();
      ref.read(filteredTransactionsProvider.notifier).refresh();
      ref.read(reviewQueueProvider.notifier).refresh();
      if (gap != null) ref.read(openLedgerGapsProvider.notifier).refresh();

      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_savedMessage(gap, remainder))),
      );
    } on DuplicateManualEntry {
      _showError('You have already recorded an identical entry.');
    } catch (e) {
      _showError('Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Says what actually happened, including the case the arithmetic doesn't
  /// fully answer -- a partly-filled gap is closed here and re-opened,
  /// narrower, by tonight's reconciler run. Claiming it was "resolved" would
  /// be the one dishonest thing this screen could do.
  String _savedMessage(LedgerGapRow? gap, int? remainder) {
    if (gap == null) return 'Entry recorded.';
    if (remainder == null || remainder == 0) return 'Gap filled.';
    return 'Entry recorded. ${formatPaisa(remainder.abs(), currency: gap.currency)} '
        'is still unaccounted for — tonight\'s sync will flag what\'s left.';
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider);
    final categories = ref.watch(categoriesProvider);
    final gap = _gap;

    return Scaffold(
      appBar: AppBar(title: Text(_isGapFill ? 'Fill this gap' : 'Add transaction')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (gap != null) ...[
              _GapBrief(gap: gap),
              const SizedBox(height: 20),
            ],
            _FieldLabel(_isGapFill ? 'What was it?' : 'Details'),
            const SizedBox(height: 8),
            _DirectionToggle(
              value: _direction,
              onChanged: (d) => setState(() => _direction = d),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              decoration: InputDecoration(
                labelText: 'Amount',
                prefixText: (gap?.currency ?? primaryCurrency) == 'NPR' ? 'Rs. ' : '${gap!.currency} ',
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
              validator: (value) =>
                  parsePaisa(value ?? '') == null ? 'Enter an amount like 1250.00' : null,
            ),
            if (gap != null) ...[
              const SizedBox(height: 8),
              _RemainderNote(gap: gap, remainderPaisa: _remainderPaisa),
            ],
            const SizedBox(height: 12),
            TextFormField(
              controller: _description,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText: 'Where did the money go?',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  (value ?? '').trim().isEmpty ? 'Say what this was, so it means something later' : null,
            ),
            const SizedBox(height: 24),
            _FieldLabel('When'),
            const SizedBox(height: 8),
            _DateTimeField(
              value: _occurredAt,
              caption: gap == null
                  ? null
                  : 'Must fall inside the gap — ${_windowLabel(gap)}',
              onTap: _pickDateTime,
            ),
            const SizedBox(height: 24),
            _FieldLabel('Account'),
            const SizedBox(height: 8),
            _AccountField(
              accounts: accounts,
              selectedId: _accountId,
              // Fixing the account is not a UI nicety: the gap belongs to one
              // account's balance chain, and an entry filed elsewhere cannot
              // close it.
              locked: _isGapFill,
              onChanged: (id) => setState(() => _accountId = id),
            ),
            const SizedBox(height: 24),
            _FieldLabel('Category'),
            const SizedBox(height: 8),
            _CategoryField(
              categories: categories,
              selectedId: _categoryId,
              onChanged: (id) => setState(() => _categoryId = id),
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: _note,
              maxLines: 2,
              maxLength: 500,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                hintText: 'Anything you want to remember about this',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _saving || _accountId == null ? null : _save,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: _saving
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_isGapFill ? 'Record and close gap' : 'Record entry'),
            ),
            const SizedBox(height: 12),
            Text(
              _isGapFill
                  ? 'This is recorded as your own entry, not the bank\'s. It carries '
                      'the balance the gap implies, so tonight\'s sync can check the '
                      'chain adds up.'
                  : 'This is recorded as your own entry, not the bank\'s. It carries no '
                      'balance, so it never interferes with the reconciler\'s check on '
                      'your bank accounts.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  static String _windowLabel(LedgerGapRow gap) {
    final fmt = DateFormat('d MMM, HH:mm');
    return '${fmt.format(gap.afterOccurredAt.toLocal())} → ${fmt.format(gap.beforeOccurredAt.toLocal())}';
  }
}

/// What the reconciler actually knows, stated plainly. This is the whole
/// reason the screen can be filled in accurately: it names the account, the
/// window, and the exact amount to look for in the bank app.
class _GapBrief extends StatelessWidget {
  const _GapBrief({required this.gap});
  final LedgerGapRow gap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final leftAccount = gap.missingDirection == Direction.debit;
    final fmt = DateFormat('d MMM yyyy, HH:mm');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  gap.accountDisplayName,
                  style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            formatPaisa(gap.missingAmountPaisa, currency: gap.currency),
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            leftAccount
                ? 'left this account with no message to explain it.'
                : 'arrived in this account with no message to explain it.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          _BriefRow(label: 'Between', value: fmt.format(gap.afterOccurredAt.toLocal())),
          _BriefRow(label: 'and', value: fmt.format(gap.beforeOccurredAt.toLocal())),
          if (gap.afterBalancePaisa != null)
            _BriefRow(
              label: 'Balance before',
              value: formatPaisa(gap.afterBalancePaisa!, currency: gap.currency),
            ),
          const SizedBox(height: 10),
          Text(
            'Open your bank app for that window and record what you find.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _BriefRow extends StatelessWidget {
  const _BriefRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(value, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

/// Live feedback on whether the amount typed actually answers the gap.
/// Silent when it does -- a confirmation for the expected case would just be
/// noise; the interesting states are "not yet" and "over".
class _RemainderNote extends StatelessWidget {
  const _RemainderNote({required this.gap, required this.remainderPaisa});
  final LedgerGapRow gap;
  final int? remainderPaisa;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remainder = remainderPaisa;
    if (remainder == null) return const SizedBox.shrink();

    if (remainder == 0) {
      return Row(
        children: [
          Icon(Icons.check_circle_outline, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Accounts for the gap exactly.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
            ),
          ),
        ],
      );
    }

    final over = (remainder < 0) == (gap.missingPaisa < 0) ? false : true;
    return Row(
      children: [
        Icon(Icons.info_outline, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            over
                ? 'That is more than the gap. The difference will be flagged as a new gap tonight.'
                : '${formatPaisa(remainder.abs(), currency: gap.currency)} would still be '
                    'unaccounted for. Record this one anyway if there was more than one '
                    'transaction — tonight\'s sync will ask about the rest.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: 0.8,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _DirectionToggle extends StatelessWidget {
  const _DirectionToggle({required this.value, required this.onChanged});
  final Direction value;
  final ValueChanged<Direction> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<Direction>(
      segments: const [
        ButtonSegment(
          value: Direction.debit,
          label: Text('Money out'),
          icon: Icon(Icons.arrow_upward, size: 16),
        ),
        ButtonSegment(
          value: Direction.credit,
          label: Text('Money in'),
          icon: Icon(Icons.arrow_downward, size: 16),
        ),
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

class _DateTimeField extends StatelessWidget {
  const _DateTimeField({required this.value, required this.onTap, this.caption});
  final DateTime value;
  final VoidCallback onTap;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.event_outlined, size: 18),
          label: Align(
            alignment: Alignment.centerLeft,
            child: Text(DateFormat('EEE d MMM yyyy, HH:mm').format(value)),
          ),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            alignment: Alignment.centerLeft,
          ),
        ),
        if (caption != null) ...[
          const SizedBox(height: 6),
          Text(
            caption!,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _AccountField extends StatelessWidget {
  const _AccountField({
    required this.accounts,
    required this.selectedId,
    required this.locked,
    required this.onChanged,
  });
  final AsyncValue<List<Account>> accounts;
  final String? selectedId;
  final bool locked;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return accounts.when(
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text('Could not load accounts: $e'),
      data: (rows) {
        if (rows.isEmpty) {
          return const Text(
            'No accounts yet. The worker creates one the first time it sees a '
            'transaction from it, so run a sync before adding entries by hand.',
          );
        }
        // Default to Cash on a free-standing entry. Bank and wallet
        // transactions arrive on their own through the pipeline, so the
        // reason to be typing one in by hand is almost always that no
        // machine saw it -- which means cash. Still a plain dropdown value,
        // visibly selected and one tap from being changed, not a hidden
        // assumption. Gap fills are locked to the gap's own account and
        // never reach this.
        if (selectedId == null && !locked) {
          final fallback = _defaultAccount(rows);
          if (fallback != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) => onChanged(fallback.id));
          }
        }
        return DropdownButtonFormField<String>(
          initialValue: selectedId,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          // Without this the dropdown sizes itself to its widest item and
          // overflows the field rather than wrapping -- which is what the
          // 36px overflow stripe was.
          isExpanded: true,
          items: [
            for (final a in rows)
              DropdownMenuItem(
                value: a.id,
                child: Text(_accountLabel(a), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: locked ? null : onChanged,
          validator: (value) => value == null ? 'Pick an account' : null,
        );
      },
    );
  }
}

/// Cash if it exists, otherwise the only account when there is exactly one.
/// Returns null when there is a real choice to make and no obvious default.
Account? _defaultAccount(List<Account> rows) {
  for (final a in rows) {
    if (a.institution == 'CASH') return a;
  }
  return rows.length == 1 ? rows.first : null;
}

/// `firstOrNull` lives in package:collection, which this app doesn't depend
/// on for one lookup.
Category? _findById(List<Category> rows, String? id) {
  if (id == null) return null;
  for (final c in rows) {
    if (c.id == id) return c;
  }
  return null;
}

/// The worker builds display_name as "INSTITUTION MASK" already
/// (store/supabase.py::get_or_create_account), so appending the mask again
/// printed "NABIL 001#####234567 · 001#####234567" and blew through the
/// field. Only add it when it isn't already in there.
String _accountLabel(Account a) {
  final mask = a.mask;
  if (mask == null || mask.isEmpty || a.displayName.contains(mask)) return a.displayName;
  return '${a.displayName} · $mask';
}

class _CategoryField extends StatelessWidget {
  const _CategoryField({
    required this.categories,
    required this.selectedId,
    required this.onChanged,
  });
  final AsyncValue<List<Category>> categories;
  final String? selectedId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return categories.when(
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text('Could not load categories: $e'),
      data: (rows) {
        final selected = _findById(rows, selectedId);
        final group = _findById(rows, selected?.parentId);
        return OutlinedButton(
          onPressed: () async {
            final picked = await showCategoryPickerSheet(
              context,
              categories: rows,
              selectedId: selectedId,
            );
            if (picked != null) onChanged(picked);
          },
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            alignment: Alignment.centerLeft,
          ),
          child: Row(
            children: [
              Expanded(
                child: selected == null
                    ? Text(
                        'Leave for review',
                        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                      )
                    : Text.rich(
                        TextSpan(children: [
                          if (group != null)
                            TextSpan(
                              text: '${group.name}  ',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          TextSpan(
                            text: selected.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ]),
                      ),
              ),
              const Icon(Icons.chevron_right, size: 20),
            ],
          ),
        );
      },
    );
  }
}
