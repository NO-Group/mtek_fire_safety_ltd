import 'package:flutter/gestures.dart';
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

/// App-wide scroll behaviour (owner directive 2026-09-01: "every screen in
/// the Windows build should have a visible scroller"). On desktop platforms
/// this (a) always draws a visible, always-on scrollbar — not just the
/// hover/drag flash Flutter shows by default — and (b) lets a mouse drag
/// scroll content, same as the login screen already did. Applied once here
/// on the root MaterialApp so every screen in the app gets it for free,
/// without needing a Scrollbar wrapper hand-added to each one.
class MtekScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.unknown,
      };

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    switch (getPlatform(context)) {
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        // Force it always-visible; the default only flashes on hover/scroll.
        return Scrollbar(
          controller: details.controller,
          thumbVisibility: true,
          child: child,
        );
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.iOS:
        return super.buildScrollbar(context, child, details);
    }
  }
}

class MtekApp extends StatelessWidget {
  const MtekApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MFSL Inventory',
      debugShowCheckedModeBanner: false,
      scrollBehavior: MtekScrollBehavior(),
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
    // AppStore.init() first (creates the RestClient/ApiClient the session
    // restore needs), THEN silently try to resume a saved session from the
    // last app run before deciding whether to show the login screen — this
    // is what keeps the user signed in across app exits (owner directive
    // 2026-09-01; previously every restart forced a fresh sign-in).
    AppStore.instance.init().then((_) async {
      await AuthStore.instance.restoreSession();
      AuthStore.instance.ping();
    });
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
