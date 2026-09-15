import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/stale_async_notifier.dart';
import '../../data/transactions_repository.dart';
import '../../models/enums.dart';
import '../../models/transaction.dart';

class _ReviewQueueNotifier extends StaleAsyncNotifier<List<Txn>> {
  @override
  Duration get staleTime => const Duration(minutes: 3);

  @override
  Future<List<Txn>> fetch() =>
      ref.read(transactionsRepositoryProvider).fetchByStatus(TxnStatus.needsReview);
}

final reviewQueueProvider = AsyncNotifierProvider<_ReviewQueueNotifier, List<Txn>>(
  _ReviewQueueNotifier.new,
);

// A single transaction, keyed by id. Kept as a plain family FutureProvider
// rather than a StaleAsyncNotifier -- it's a short-lived detail lookup, not
// something a screen needs to periodically re-check for staleness, and
// Riverpod already caches each id's result independently.
final transactionByIdProvider = FutureProvider.family<Txn, String>((ref, id) {
  return ref.watch(transactionsRepositoryProvider).fetchOne(id);
});

/// Transactions for one calendar day, keyed by that day -- the heatmap's
/// tap-a-square drill-down. Same reasoning as transactionByIdProvider for
/// staying a plain family provider rather than a StaleAsyncNotifier.
final transactionsByDateProvider = FutureProvider.family<List<Txn>, DateTime>((ref, day) {
  return ref.watch(transactionsRepositoryProvider).fetchByDate(day);
});
