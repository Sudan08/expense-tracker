import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/cache/stale_async_notifier.dart';
import '../core/supabase/supabase_providers.dart';
import '../models/merchant_rule.dart';

/// merchant_rules read/write from the phone.
///
/// The RLS grant (migration 20260908020000) is column-level: pattern,
/// category_id, counterparty_label, priority. learned_from_user, hit_count,
/// and created_at are never sent in an update -- Postgres would reject them
/// anyway, but not sending them keeps that boundary visible in the Dart too.
class MerchantRulesRepository {
  MerchantRulesRepository(this._client);
  final SupabaseClient _client;

  Future<List<MerchantRule>> fetchAll() async {
    final rows = await _client
        .from('merchant_rules')
        .select('*, categories(name)')
        .order('hit_count', ascending: false);
    return (rows as List).map((r) => MerchantRule.fromRow(r as Map<String, dynamic>)).toList();
  }

  Future<void> update({
    required String id,
    required String pattern,
    required String categoryId,
    String? counterpartyLabel,
    required int priority,
  }) async {
    await _client.from('merchant_rules').update({
      'pattern': pattern,
      'category_id': categoryId,
      'counterparty_label': counterpartyLabel,
      'priority': priority,
    }).eq('id', id);
  }

  Future<void> delete(String id) async {
    await _client.from('merchant_rules').delete().eq('id', id);
  }
}

final merchantRulesRepositoryProvider = Provider<MerchantRulesRepository>((ref) {
  return MerchantRulesRepository(ref.watch(supabaseClientProvider));
});

class _MerchantRulesNotifier extends StaleAsyncNotifier<List<MerchantRule>> {
  @override
  Duration get staleTime => const Duration(minutes: 15);

  @override
  Future<List<MerchantRule>> fetch() => ref.read(merchantRulesRepositoryProvider).fetchAll();
}

final merchantRulesProvider = AsyncNotifierProvider<_MerchantRulesNotifier, List<MerchantRule>>(
  _MerchantRulesNotifier.new,
);
