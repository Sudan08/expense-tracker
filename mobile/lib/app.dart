import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/notifications/daily_reminder.dart';
import 'core/router.dart';
import 'core/theme.dart';

class ExpenseTrackerApp extends ConsumerStatefulWidget {
  const ExpenseTrackerApp({super.key});

  @override
  ConsumerState<ExpenseTrackerApp> createState() => _ExpenseTrackerAppState();
}

class _ExpenseTrackerAppState extends ConsumerState<ExpenseTrackerApp> {
  @override
  void initState() {
    super.initState();
    _followNotificationTap();
  }

  /// If the app was launched by tapping the 22:00 reminder, go where the
  /// reminder was pointing -- the gap list when there was something to fill,
  /// the add form when there wasn't.
  ///
  /// Only the cold-launch case is handled, which is the one that matters: a
  /// tap while the app is already running just brings it to the foreground,
  /// where everything is already on screen. Deliberately after the first
  /// frame, so the router exists and its auth redirect has settled -- a push
  /// before then lands on /login and is redirected straight back off again.
  void _followNotificationTap() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final reminder = await ref.read(dailyReminderProvider.future);
        final route = await reminder.launchRoute();
        if (route == null || !mounted) return;
        ref.read(routerProvider).push(route);
      } catch (_) {
        // A reminder tap that fails to route just opens the app normally.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Expense Tracker',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      routerConfig: router,
    );
  }
}
