import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/auth_store.dart';
import '../../data/env.dart';
import '../signature_pad.dart';

/// Desktop (Windows/macOS/Linux) builds don't enable mouse-drag scrolling
/// by default -- only touch/stylus/mouse-wheel. On a short window the
/// longer Create Account form can end up with fields below the fold and
/// no obvious way to reach them, so this screen opts into mouse-drag
/// scrolling too (in addition to the wheel, which already worked).
class _DesktopScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.unknown,
      };
}

/// Sign-in / create-account. Account creation REQUIRES a Signature
/// Passcode (separate from the password) + optional drawn signature.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _signup = false;
  String? _error;

  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  final _passcode = TextEditingController();
  final _passcode2 = TextEditingController();
  String _role = 'admin';
  String? _signaturePng;
  bool _showPad = false;
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    _email.dispose();
    _password.dispose();
    _name.dispose();
    _passcode.dispose();
    _passcode2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Mtek.navy950,
      body: Center(
        child: ScrollConfiguration(
          behavior: _DesktopScrollBehavior(),
          child: Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Card(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(26),
                    child: _signup ? _buildSignup() : _buildLogin(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _logoHeader(String title) {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1E3FA0).withValues(alpha: .18),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Image.asset('assets/branding/logo.png', fit: BoxFit.contain),
        ),
        const SizedBox(height: 12),
        const Text('M-TEK FIRE & SAFETY LTD',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1, fontSize: 13, color: Mtek.navy800)),
        const SizedBox(height: 4),
        Text(title, style: const TextStyle(color: Mtek.gray500, fontSize: 13)),
        const SizedBox(height: 18),
      ],
    );
  }

  Widget _buildLogin() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _logoHeader('Sign in to your workspace'),
        TextField(controller: _email, decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline))),
        const SizedBox(height: 12),
        TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline))),
        const SizedBox(height: 16),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!, style: const TextStyle(color: Mtek.danger, fontSize: 13)),
          ),
        FilledButton(
          onPressed: _busy ? null : _signIn,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Sign in'),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => setState(() { _signup = true; _error = null; }),
          child: const Text('Create an account →'),
        ),
        const SizedBox(height: 6),
      ],
    );
  }

  Widget _buildSignup() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _logoHeader('Create your account'),
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Full name', prefixIcon: Icon(Icons.person_outline))),
        const SizedBox(height: 10),
        TextField(controller: _email, decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline))),
        const SizedBox(height: 10),
        TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Account password (min 6)', prefixIcon: Icon(Icons.lock_outline))),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Mtek.goldTint, borderRadius: BorderRadius.circular(12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(children: [
                Icon(Icons.draw_outlined, size: 17, color: Mtek.warn),
                SizedBox(width: 7),
                Text('SIGNATURE PASSCODE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1, color: Mtek.warn)),
              ]),
              const SizedBox(height: 4),
              const Text('Used to digitally sign receipts, invoices & MILS logs — no more signing on paper. Must differ from your password.',
                  style: TextStyle(fontSize: 11.5, color: Mtek.gray600)),
              const SizedBox(height: 10),
              TextField(controller: _passcode, obscureText: true, decoration: const InputDecoration(labelText: 'Signature passcode (min 4)')),
              const SizedBox(height: 8),
              TextField(controller: _passcode2, obscureText: true, decoration: const InputDecoration(labelText: 'Repeat signature passcode')),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (Env.backendConfigured)
          // Real accounts always start as Sales (server-enforced too) — no
          // self-service Admin/CEO, for the same reason a bank teller can't
          // promote themselves to branch manager. An existing Admin/CEO
          // upgrades staff afterwards via the Supabase dashboard.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: Mtek.gray100, borderRadius: BorderRadius.circular(10)),
            child: Row(
              children: const [
                Icon(Icons.info_outline, size: 16, color: Mtek.gray500),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'New accounts start as Sales staff. An Admin or the CEO can promote you afterwards.',
                    style: TextStyle(fontSize: 12, color: Mtek.gray600),
                  ),
                ),
              ],
            ),
          )
        else
          Row(
            children: [
              const Text('Role', style: TextStyle(color: Mtek.gray500)),
              const SizedBox(width: 12),
              ChoiceChip(label: const Text('Admin'), selected: _role == 'admin', onSelected: (_) => setState(() => _role = 'admin')),
              const SizedBox(width: 8),
              ChoiceChip(label: const Text('Sales'), selected: _role == 'sales', onSelected: (_) => setState(() => _role = 'sales')),
            ],
          ),
        const SizedBox(height: 10),
        // Drawn signature is optional; the passcode is what authorises documents.
        if (_showPad)
          SignaturePad(
            onDone: (bytes) {
              setState(() {
                _showPad = false;
                if (bytes != null) _signaturePng = signatureDataUrl(bytes);
              });
            },
          )
        else
          OutlinedButton.icon(
            onPressed: () => setState(() => _showPad = true),
            icon: const Icon(Icons.gesture, size: 18),
            label: Text(_signaturePng == null ? 'Draw your signature (optional)' : 'Signature saved ✓ — redraw'),
          ),
        const SizedBox(height: 14),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!, style: const TextStyle(color: Mtek.danger, fontSize: 13)),
          ),
        FilledButton(
          onPressed: _busy ? null : _createAccount,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Create account'),
        ),
        TextButton(
          onPressed: () => setState(() { _signup = false; _error = null; }),
          child: const Text('← Back to sign in'),
        ),
      ],
    );
  }

  bool _busy = false;

  Future<void> _signIn() async {
    // REAL backend first (Supabase Auth + profiles role); offline dev
    // (backend not configured) falls back to the local directory.
    if (Env.backendConfigured) {
      setState(() { _busy = true; _error = null; });
      final remoteErr = await AuthStore.instance.remoteSignIn(_email.text, _password.text);
      if (!mounted) return;
      setState(() { _busy = false; _error = remoteErr; });
      return;
    }
    final err = AuthStore.instance.signIn(_email.text, _password.text);
    setState(() => _error = err);
  }

  Future<void> _createAccount() async {
    if (_passcode.text != _passcode2.text) {
      setState(() => _error = 'Signature passcodes do not match');
      return;
    }
    // REAL backend: create an actual Supabase account (owner directive
    // 2026-09-01) instead of the local-only fake that had no server
    // permissions and made every write get rejected.
    if (Env.backendConfigured) {
      setState(() { _busy = true; _error = null; });
      final remoteErr = await AuthStore.instance.remoteSignUp(
        name: _name.text,
        email: _email.text,
        password: _password.text,
        signaturePasscode: _passcode.text,
      );
      if (!mounted) return;
      setState(() { _busy = false; _error = remoteErr; });
      return;
    }
    final err = AuthStore.instance.signUp(
      name: _name.text,
      email: _email.text,
      password: _password.text,
      signaturePasscode: _passcode.text,
      role: _role,
      signaturePng: _signaturePng,
    );
    setState(() => _error = err);
  }
}
