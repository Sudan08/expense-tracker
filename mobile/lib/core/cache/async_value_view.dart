import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Renders an [AsyncValue] with exactly one loading moment per provider,
/// ever: the very first fetch, before anything has been cached. After that,
/// [StaleAsyncNotifier.refresh]/[ensureFresh] keep `hasValue` true for the
/// whole duration of a refetch (see stale_async_notifier.dart), so this
/// falls into [data] and shows the cached value instead of flashing back to
/// a spinner every time a screen re-checks freshness or a pull-to-refresh
/// fires. Use `RefreshIndicator`'s own spinner as the *only* loading
/// affordance for a refetch-with-cached-data; this widget deliberately has
/// no "refreshing" branch to put a second one next to it.
class AsyncValueView<T> extends StatelessWidget {
  const AsyncValueView({
    super.key,
    required this.value,
    required this.data,
    required this.loading,
    required this.error,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final Widget Function() loading;
  final Widget Function(Object error) error;

  @override
  Widget build(BuildContext context) {
    if (value.hasValue) return data(value.value as T);
    if (value.hasError) return error(value.error!);
    return loading();
  }
}
