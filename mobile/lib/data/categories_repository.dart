import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/cache/stale_async_notifier.dart';
import '../core/supabase/supabase_providers.dart';
import '../models/category.dart';

class CategoriesRepository {
  CategoriesRepository(this._client);
  final SupabaseClient _client;

  Future<List<Category>> fetchAll() async {
    final rows = await _client.from('categories').select().order('name');
    return (rows as List).map((r) => Category.fromRow(r as Map<String, dynamic>)).toList();
  }
}

final categoriesRepositoryProvider = Provider<CategoriesRepository>((ref) {
  return CategoriesRepository(ref.watch(supabaseClientProvider));
});

class _CategoriesNotifier extends StaleAsyncNotifier<List<Category>> {
  // Categories are edited from the merchant rules / recategorize screens,
  // not on any schedule -- a long stale time is fine, and those screens
  // invalidate this provider themselves right after a write anyway.
  @override
  Duration get staleTime => const Duration(hours: 1);

  @override
  Future<List<Category>> fetch() => ref.read(categoriesRepositoryProvider).fetchAll();
}

/// Cached category list -- small, changes rarely, and every screen that
/// shows or edits a category needs it.
final categoriesProvider = AsyncNotifierProvider<_CategoriesNotifier, List<Category>>(
  _CategoriesNotifier.new,
);
