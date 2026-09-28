import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  String? url;
  String? anonKey;
  try {
    await dotenv.load(fileName: '.env');
    url = dotenv.env['SUPABASE_URL'];
    anonKey = dotenv.env['SUPABASE_ANON_KEY'];
  } catch (_) {
    // .env isn't bundled yet -- fall through to the setup screen below.
  }

  if (url == null ||
      url.isEmpty ||
      anonKey == null ||
      anonKey.isEmpty ||
      url.contains('YOUR-PROJECT-REF') ||
      anonKey == 'your-anon-key') {
    runApp(const _NotConfiguredApp());
    return;
  }

  await Supabase.initialize(url: url, publishableKey: anonKey);
  runApp(const ProviderScope(child: ExpenseTrackerApp()));
}

/// Shown when mobile/.env hasn't been created yet. Run
/// scripts/setup-wizard.sh from the repo root first (plan section 12,
/// Phase 6) -- it provisions the Supabase project this app reads from.
class _NotConfiguredApp extends StatelessWidget {
  const _NotConfiguredApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.settings_outlined, size: 48),
                  const SizedBox(height: 16),
                  Text('App not configured', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  const Text(
                    'Copy mobile/.env.example to mobile/.env and fill in the '
                    'Supabase project URL and anon key from '
                    'scripts/setup-wizard.sh, then rebuild.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
