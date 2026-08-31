import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'data/auth_store.dart';
import 'data/store.dart';
import 'ui/app_shell.dart';
import 'ui/screens/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MtekApp());
}

class MtekApp extends StatelessWidget {
  const MtekApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MFSL Inventory',
      debugShowCheckedModeBanner: false,
      theme: MtekTheme.light(),
      home: AnimatedBuilder(
        animation: Listenable.merge([AuthStore.instance, AppStore.instance]),
        builder: (context, _) {
          if (!AppStore.instance.isLoaded) {
            return const _BootScreen();
          }
          return AuthStore.instance.isSignedIn ? const AppShell() : const LoginScreen();
        },
      ),
    );
  }
}

/// Loads the local database / seed data on first frame (Phase B).
class _BootScreen extends StatefulWidget {
  const _BootScreen();

  @override
  State<_BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<_BootScreen> {
  @override
  void initState() {
    super.initState();
    AppStore.instance.init().then((_) => AuthStore.instance.ping());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Mtek.navy950,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: Mtek.brand600, borderRadius: BorderRadius.circular(16)),
              child: Image.asset('assets/branding/logo.png', fit: BoxFit.contain),
            ),
            const SizedBox(height: 16),
            const Text('M-TEK FIRE & SAFETY LTD.',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, letterSpacing: 1)),
            const SizedBox(height: 10),
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(color: Mtek.gold500, strokeWidth: 2.5),
            ),
          ],
        ),
      ),
    );
  }
}
