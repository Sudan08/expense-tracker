import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/cache/stale_async_notifier.dart';
import '../core/supabase/supabase_providers.dart';
import '../models/account.dart';

/// The account list, needed by any form that asks "which account was this?".
/// Read-only: accounts are created by the worker the first time it sees a
/// transaction from one (store.get_or_create_account), never by the phone --
/// an account the pipeline has never seen is an account with no transactions
/// to attach to anything.
class AccountsRepository {
  AccountsRepository(this._client);
  final SupabaseClient _client;

  Future<List<Account>> fetchAll() async {
    final rows = await _client.from('accounts').select().order('display_name');
    return (rows as List).map((r) => Account.fromRow(r as Map<String, dynamic>)).toList();
  }
}

final accountsRepositoryProvider = Provider<AccountsRepository>((ref) {
  return AccountsRepository(ref.watch(supabaseClientProvider));
});

class _AccountsNotifier extends StaleAsyncNotifier<List<Account>> {
  // A new account appears at most when you open one at a new bank. An hour
  // matches categoriesProvider, for the same reason.
  @override
  Duration get staleTime => const Duration(hours: 1);

  @override
  Future<List<Account>> fetch() => ref.read(accountsRepositoryProvider).fetchAll();
}

final accountsProvider = AsyncNotifierProvider<_AccountsNotifier, List<Account>>(
  _AccountsNotifier.new,
);
