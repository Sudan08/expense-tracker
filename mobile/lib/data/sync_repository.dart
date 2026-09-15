import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/cache/stale_async_notifier.dart';
import '../core/supabase/supabase_providers.dart';
import '../models/sync_run.dart';

class SyncRepository {
  SyncRepository(this._client);
  final SupabaseClient _client;

  /// Plan section 14: "the app should show 'last synced 6 days ago'
  /// prominently rather than implying it's live." This is that read.
  Future<SyncRun?> lastRun() async {
    final rows = await _client
        .from('sync_runs')
        .select()
        .not('completed_at', 'is', null)
        .order('completed_at', ascending: false)
        .limit(1);
    final list = rows as List;
    if (list.isEmpty) return null;
    return SyncRun.fromRow(list.first as Map<String, dynamic>);
  }
}

final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  return SyncRepository(ref.watch(supabaseClientProvider));
});

class _LastSyncRunNotifier extends StaleAsyncNotifier<SyncRun?> {
  // The worker runs at most once a day, but this is also the thing that
  // tells you a sync is actively failing right now -- short stale time so
  // a resumed app checks again promptly rather than showing yesterday's
  // "last synced" banner for a while after opening.
  @override
  Duration get staleTime => const Duration(minutes: 3);

  @override
  Future<SyncRun?> fetch() => ref.read(syncRepositoryProvider).lastRun();
}

final lastSyncRunProvider = AsyncNotifierProvider<_LastSyncRunNotifier, SyncRun?>(
  _LastSyncRunNotifier.new,
);
