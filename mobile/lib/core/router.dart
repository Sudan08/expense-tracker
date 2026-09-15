import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/auth/login_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/manual_entry/gap_fill_route.dart';
import '../features/manual_entry/manual_entry_screen.dart';
import '../features/data_health/data_health_screen.dart';
import '../features/review/review_queue_screen.dart';
import '../features/rules/merchant_rules_screen.dart';
import '../features/shell/app_shell.dart';
import '../features/sms/sms_screen.dart';
import '../features/transactions/transaction_detail_screen.dart';
import '../features/transactions/transaction_list_screen.dart';
import 'supabase/supabase_providers.dart';

/// Bridges Supabase's auth stream to a Listenable so GoRouter re-evaluates
/// `redirect` on sign-in/sign-out without the app needing to rebuild the
/// whole router by hand.
class _AuthChangeNotifier extends ChangeNotifier {
  _AuthChangeNotifier(Stream<AuthState> stream) {
    _sub = stream.listen((_) => notifyListeners());
  }
  late final StreamSubscription _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final client = ref.watch(supabaseClientProvider);
  final authNotifier = _AuthChangeNotifier(client.auth.onAuthStateChange);
  ref.onDispose(authNotifier.dispose);

  return GoRouter(
    initialLocation: '/dashboard',
    refreshListenable: authNotifier,
    redirect: (context, state) {
      final loggedIn = client.auth.currentSession != null;
      final onLogin = state.matchedLocation == '/login';
      if (!loggedIn && !onLogin) return '/login';
      if (loggedIn && onLogin) return '/dashboard';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/dashboard', builder: (context, state) => const DashboardScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/transactions', builder: (context, state) => const TransactionListScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/review', builder: (context, state) => const ReviewQueueScreen()),
          ]),
        ],
      ),
      GoRoute(path: '/sms', builder: (context, state) => const SmsScreen()),
      GoRoute(path: '/add', builder: (context, state) => const ManualEntryScreen()),
      // The gap itself isn't passed through `extra`: that doesn't survive a
      // process restart or a deep link, and a gap can be closed by the
      // worker between the list being drawn and this being opened. Resolving
      // by id against the live list means a stale tap says so plainly
      // instead of filling a gap that no longer exists.
      GoRoute(
        path: '/gaps/:id/fill',
        builder: (context, state) => GapFillRoute(gapId: state.pathParameters['id']!),
      ),
      GoRoute(path: '/data-health', builder: (context, state) => const DataHealthScreen()),
      GoRoute(path: '/merchant-rules', builder: (context, state) => const MerchantRulesScreen()),
      GoRoute(
        path: '/transactions/:id',
        builder: (context, state) => TransactionDetailScreen(transactionId: state.pathParameters['id']!),
      ),
    ],
  );
});
