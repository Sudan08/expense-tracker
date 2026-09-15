import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/notifications/daily_reminder.dart';
import '../../core/supabase/supabase_providers.dart';
import '../../data/categories_repository.dart';
import '../../data/data_health_repository.dart';
import '../../data/merchant_rules_repository.dart';
import '../../data/sms_repository.dart';
import '../../data/sync_repository.dart';
import '../dashboard/daily_spend_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../transactions/filtered_transactions_controller.dart';
import '../transactions/transactions_controller.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Pick up bank SMS that arrived since the app was last open, but only
    // once the user has enrolled on the SMS screen -- scanIfAlreadyEnrolled
    // is a no-op before then, so opening the app never springs a READ_SMS
    // dialog on someone who didn't ask for it. Failures here are silent on
    // purpose: staging SMS is a background nicety, and the SMS screen is
    // where the user goes to see what actually happened.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final result = await ref.read(smsRepositoryProvider).scanIfAlreadyEnrolled();
        if (result != null && result.uploaded > 0 && mounted) {
          ref.invalidate(smsStatusCountsProvider);
        }
      } catch (_) {
        // Deliberately swallowed -- see above.
      }
    });

    // Ask for notification permission once the app is actually on screen,
    // then put tonight's reminder in place. Both are best-effort: a denied
    // permission or an unavailable plugin must never stop the app loading.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final reminder = await ref.read(dailyReminderProvider.future);
        await reminder.requestPermission();
        await _rescheduleReminder();
      } catch (_) {
        // Deliberately swallowed -- see above.
      }
    });
  }

  /// Rewrite tonight's reminder with the counts the app can currently see.
  ///
  /// The text of a scheduled local notification is fixed when it is
  /// scheduled, so "2 gaps to fill" is only ever as fresh as the last time
  /// this ran. Running it on every resume is what keeps that from going
  /// stale -- and the copy in DailyReminder says "as of your last check"
  /// rather than pretending otherwise.
  Future<void> _rescheduleReminder() async {
    try {
      final reminder = await ref.read(dailyReminderProvider.future);
      await reminder.schedule(
        openGaps: ref.read(openLedgerGapsProvider).valueOrNull?.length ?? 0,
        needsReview: ref.read(reviewQueueProvider).valueOrNull?.length ?? 0,
      );
    } catch (_) {
      // A reminder that fails to reschedule keeps whatever it had.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // This is what makes the staleTime on every StaleAsyncNotifier actually
  // do something beyond pull-to-refresh: the natural moment data goes stale
  // without the user doing anything is "I put my phone away and picked it
  // back up." Tab switches don't refire this -- StatefulShellRoute keeps
  // each branch's widget subtree alive, so nothing re-mounts and nothing
  // re-fetches just from tapping between Dashboard/Transactions/Review.
  // ensureFresh() is the point of the whole exercise: it's a no-op unless
  // the cached value is actually older than that provider's staleTime, so
  // this fires on every resume but rarely results in a real network call.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    ref.read(monthlySpendProvider.notifier).ensureFresh();
    ref.read(dailySpendProvider.notifier).ensureFresh();
    ref.read(earliestTransactionAtProvider.notifier).ensureFresh();
    ref.read(filteredTransactionsProvider.notifier).ensureFresh();
    ref.read(reviewQueueProvider.notifier).ensureFresh();
    ref.read(categoriesProvider.notifier).ensureFresh();
    ref.read(merchantRulesProvider.notifier).ensureFresh();
    ref.read(openLedgerGapsProvider.notifier).ensureFresh();
    ref.read(failedEmailsProvider.notifier).ensureFresh();
    ref.read(rawMessageIssuesProvider.notifier).ensureFresh();
    ref.read(smsStatusCountsProvider.notifier).ensureFresh();
    ref.read(lastSyncRunProvider.notifier).ensureFresh();
    _rescheduleReminder();
  }

  @override
  Widget build(BuildContext context) {
    final navigationShell = widget.navigationShell;
    final reviewCount = ref.watch(reviewQueueProvider).valueOrNull?.length ?? 0;
    final gapCount = ref.watch(openLedgerGapsProvider).valueOrNull?.length ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Expense Tracker'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More',
            onSelected: (route) => context.push(route),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: '/sms',
                child: ListTile(leading: Icon(Icons.sms_outlined), title: Text('Bank SMS')),
              ),
              PopupMenuItem(
                value: '/data-health',
                child: ListTile(
                  leading: const Icon(Icons.health_and_safety_outlined),
                  title: const Text('Data health'),
                  // The count is the point: an unfilled gap is a hole in
                  // your totals, and it was previously invisible unless you
                  // went looking for it.
                  trailing: gapCount == 0 ? null : Badge(label: Text('$gapCount')),
                ),
              ),
              const PopupMenuItem(
                value: '/merchant-rules',
                child: ListTile(leading: Icon(Icons.rule_folder_outlined), title: Text('Merchant rules')),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => ref.read(supabaseClientProvider).auth.signOut(),
          ),
        ],
      ),
      body: navigationShell,
      // Adding a transaction by hand is a primary action now, not something
      // buried in the overflow menu: it's how you record cash, and how you
      // answer the 22:00 reminder. Hidden on the Review tab, whose whole job
      // is already a queue of decisions -- a second call to action there
      // competes with the one the screen exists for.
      floatingActionButton: navigationShell.currentIndex == 2
          ? null
          : FloatingActionButton.extended(
              onPressed: () => context.push('/add'),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
              tooltip: 'Record a transaction by hand',
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (i) => navigationShell.goBranch(
          i,
          initialLocation: i == navigationShell.currentIndex,
        ),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Dashboard'),
          const NavigationDestination(icon: Icon(Icons.list_alt_outlined), selectedIcon: Icon(Icons.list_alt), label: 'Transactions'),
          NavigationDestination(
            icon: Badge(
              label: Text('$reviewCount'),
              isLabelVisible: reviewCount > 0,
              child: const Icon(Icons.rule_outlined),
            ),
            selectedIcon: const Icon(Icons.rule),
            label: 'Review',
          ),
        ],
      ),
    );
  }
}
