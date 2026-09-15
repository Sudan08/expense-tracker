import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/cache/async_value_view.dart';
import '../transactions/transactions_controller.dart';
import '../transactions/widgets/txn_tile.dart';

class ReviewQueueScreen extends ConsumerWidget {
  const ReviewQueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(reviewQueueProvider);

    return RefreshIndicator(
      onRefresh: () => ref.read(reviewQueueProvider.notifier).refresh(),
      child: AsyncValueView(
        value: queue,
        data: (rows) {
          if (rows.isEmpty) {
            return ListView(
              children: const [
                Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('Nothing needs review. 🎉')),
                ),
              ],
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, index) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final txn = rows[i];
              return TxnTile(
                txn: txn,
                showStatusBadge: false,
                onTap: () => context.push('/transactions/${txn.id}'),
              );
            },
          );
        },
        loading: () => ListView(children: [
          SizedBox(height: 200, child: Center(child: CircularProgressIndicator())),
        ]),
        error: (e) => ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(child: Text('Could not load the review queue: $e')),
            ),
          ],
        ),
      ),
    );
  }
}
