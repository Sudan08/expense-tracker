import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/async_value_view.dart';
import '../../data/data_health_repository.dart';
import '../../models/data_health.dart';
import 'manual_entry_screen.dart';

/// Resolves `/gaps/:id/fill` to the gap it names, then hands off to
/// [ManualEntryScreen].
///
/// The indirection earns its keep in one case: a gap the worker closed
/// between the list being drawn and this being opened. That is not
/// hypothetical here -- the 21:30 sync runs half an hour before the reminder
/// that sends you to this screen, and it closes any gap whose missing
/// transaction finally arrived. Filling one that no longer exists would
/// insert a duplicate transaction and leave the balance chain worse than it
/// started.
class GapFillRoute extends ConsumerWidget {
  const GapFillRoute({super.key, required this.gapId});

  final String gapId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gaps = ref.watch(openLedgerGapsProvider);

    return AsyncValueView(
      value: gaps,
      loading: () => const _Placeholder(child: CircularProgressIndicator()),
      error: (e) => _Placeholder(child: Text('Could not load the gap: $e')),
      data: (rows) {
        final gap = _find(rows, gapId);
        if (gap == null) return const _GapGone();
        return ManualEntryScreen(gap: gap);
      },
    );
  }

  static LedgerGapRow? _find(List<LedgerGapRow> rows, String id) {
    for (final g in rows) {
      if (g.id == id) return g;
    }
    return null;
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Fill this gap')),
        body: Center(child: Padding(padding: const EdgeInsets.all(24), child: child)),
      );
}

class _GapGone extends StatelessWidget {
  const _GapGone();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Fill this gap')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_outline, size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('Nothing to fill', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'This gap has already been closed — either the missing message '
                'finally arrived and a sync parsed it, or you filled it '
                'somewhere else.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
