import 'package:flutter/material.dart';
import '../../core/app_info.dart';
import '../../core/theme.dart';
import '../../core/theme_controller.dart';
import '../../data/auth_store.dart';
import '../../data/env.dart';
import '../../data/store.dart';
import '../../documents/forms_spec.dart';
import '../../documents/serial_service.dart';
import '../widgets.dart';

/// SETTINGS — visible to EVERY role (owner directive 2026-09-01).
///
/// Every signed-in user sees:
///   • Account      — profile, change password, change signature passcode,
///                    recovery (reset password/passcode + reset recovery
///                    string), and sign out.
///   • Preferences  — mark all notifications read, refresh from the server.
///   • About        — app version + live server status.
///
/// The management controls (VAT, document serial reseed, stock TXT import,
/// company profile) stay CEO-only.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _tsv = TextEditingController();
  String _importMsg = '';
  bool? _online; // null = still checking

  @override
  void initState() {
    super.initState();
    _ping();
  }

  @override
  void dispose() {
    _tsv.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    final auth = AuthStore.instance;
    final user = auth.current;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const PageHeader(
          title: 'Settings',
          subtitle: 'Your account, preferences and app information',
          icon: Icons.settings,
        ),
        const SizedBox(height: 16),

        // ---------------- Account (every role) ----------------
        _sectionLabel('ACCOUNT'),
        Card(
          child: Column(children: [
            ListTile(
              leading: InitialsAvatar(_initials(user?.name), background: Mtek.brand600),
              title: Text(user?.name ?? '—', style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(user?.email ?? ''),
              trailing: StatusChip.neutral((user?.role ?? '').toUpperCase()),
            ),
            const Divider(height: 1, color: Mtek.gray100),
            ListTile(
              leading: const Icon(Icons.lock_outline, color: Mtek.navy700),
              title: const Text('Change password'),
              trailing: const Icon(Icons.chevron_right, color: Mtek.gray400),
              onTap: () => _changePassword(context),
            ),
            ListTile(
              leading: const Icon(Icons.password_outlined, color: Mtek.navy700),
              title: const Text('Change signature passcode'),
              trailing: const Icon(Icons.chevron_right, color: Mtek.gray400),
              onTap: () => _changePasscode(context),
            ),
            ListTile(
              leading: const Icon(Icons.restore_outlined, color: Mtek.navy700),
              title: const Text('Recovery'),
              subtitle: const Text('Reset your password or recovery string'),
              trailing: const Icon(Icons.chevron_right, color: Mtek.gray400),
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => const RecoveryScreen())),
            ),
            const Divider(height: 1, color: Mtek.gray100),
            ListTile(
              leading: const Icon(Icons.logout, color: Mtek.danger),
              title: const Text('Sign out', style: TextStyle(color: Mtek.danger, fontWeight: FontWeight.w600)),
              onTap: () => AuthStore.instance.signOut(),
            ),
          ]),
        ),
        const SizedBox(height: 14),

        // ---------------- Preferences (every role) ----------------
        _sectionLabel('PREFERENCES'),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.brightness_6_outlined),
              title: const Text('Appearance'),
              subtitle: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('System')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ],
                selected: {ThemeController.instance.mode},
                showSelectedIcon: false,
                onSelectionChanged: (modes) async {
                  await ThemeController.instance.setMode(modes.first);
                  if (mounted) setState(() {});
                },
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.done_all, color: Mtek.navy700),
              title: const Text('Mark all notifications as read'),
              onTap: () async {
                await AppStore.instance.markAllNotificationsRead();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('All notifications marked as read.')));
                }
              },
            ),
            const Divider(height: 1, color: Mtek.gray100),
            ListTile(
              leading: const Icon(Icons.refresh, color: Mtek.navy700),
              title: const Text('Refresh data from server'),
              subtitle: const Text('Re-download your latest records and notifications'),
              onTap: () async {
                await store.reloadRemote();
                await store.refreshNotifications();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Data refreshed.')));
                }
              },
            ),
          ]),
        ),
        const SizedBox(height: 14),

        // ---------------- About (every role) ----------------
        _sectionLabel('ABOUT'),
        Card(
          child: Column(children: [
            ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset('assets/branding/app_icon.png', width: 40, height: 40,
                    errorBuilder: (_, __, ___) => const Icon(Icons.local_fire_department, size: 32, color: Mtek.brand600)),
              ),
              title: const Text(AppInfo.appName, style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('v${AppInfo.version} · ${AppInfo.publisher}'),
            ),
            const Divider(height: 1, color: Mtek.gray100),
            ListTile(
              leading: _online == null
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(
                      _online == true ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                      color: _online == true ? Mtek.success : Mtek.gray500),
              title: Text(_online == null
                  ? 'Checking server…'
                  : (_online == true
                      ? (Env.offlineDataMode ? 'Sign-in server connected' : 'Server connected')
                      : 'Server unreachable')),
              subtitle: Text(Env.offlineDataMode
                  ? 'Offline-first mode: all records are stored on this device. Only sign-in uses the server.'
                  : (_online == true
                      ? 'Your account is synced with the live server.'
                      : 'Working offline — changes will sync when reconnected.')),
              trailing: IconButton(
                tooltip: 'Check again',
                icon: const Icon(Icons.refresh, size: 20, color: Mtek.gray500),
                onPressed: _ping,
              ),
            ),
          ]),
        ),
        const SizedBox(height: 14),

        // ---------------- CEO-only management ----------------
        if (auth.isCeo) ...[
          _sectionLabel('MANAGEMENT (CEO)'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('DOCUMENT SERIALS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1, color: Mtek.gray500)),
                  const SizedBox(height: 4),
                  const Text('Set each counter to the number of the last used page in the physical book — digital documents continue the sequence.',
                      style: TextStyle(fontSize: 12, color: Mtek.gray500)),
                  const SizedBox(height: 10),
                  for (final entry in [
                    ('receipt', 'Payment Receipt', MtekForms.seedSerials['receipt']!),
                    ('invoice', 'Sales Invoice', MtekForms.seedSerials['invoice']!),
                    ('mils', 'MILS Sheet', MtekForms.seedSerials['mils']!),
                    ('waybill', 'Waybill (starts 000000001)', MtekForms.seedSerials['waybill']!),
                    ('deliverynote', 'Delivery Note (starts 000000001)', MtekForms.seedSerials['deliverynote']!),
                  ])
                    _serialRow(context, entry.$1, entry.$2, entry.$3),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('STOCK IMPORT (TXT)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1, color: Mtek.gray500)),
                  const SizedBox(height: 4),
                  const Text('Paste the edited products_seed.txt contents (tab-separated) and import. Existing IDs are updated; new IDs are added.',
                      style: TextStyle(fontSize: 12, color: Mtek.gray500)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _tsv,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      hintText: 'ID\tNAME\tCATEGORY\tCOST PRICE (NGN)\t…',
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: const Text('Import pasted TXT'),
                    onPressed: _importTsv,
                  ),
                  if (_importMsg.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(_importMsg, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Mtek.success)),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Card(
            child: ListTile(
              leading: Icon(Icons.verified_user_outlined),
              title: Text('M-TEK FIRE & SAFETY LTD.'),
              subtitle: Text('RC: 1082534 · YY12 Kazaure Road, by Lagos Street Round About, Kaduna\nmtekfiresafetyltd@gmail.com · 08033489452'),
              isThreeLine: true,
            ),
          ),
        ],
      ],
    );
  }

  String _initials(String? name) {
    if (name == null || name.trim().isEmpty) return '?';
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: SectionTitle(text),
      );

  // ---- server status ----
  Future<void> _ping() async {
    setState(() => _online = null);
    final api = AppStore.instance.api;
    var ok = false;
    if (Env.authApiConfigured && api != null) {
      // ANY HTTP response — even a 4xx/5xx — proves the server is reachable
      // (the request round-tripped). "Unreachable" is reserved for a true
      // transport failure (offline / timeout), where httpJson returns null.
      final res = await api.get('/health');
      ok = res != null;
    }
    if (mounted) setState(() => _online = ok);
  }

  // ---- change password / passcode dialogs ----
  Future<void> _changePassword(BuildContext context) async {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    // Dialog result: null = cancelled · '' = proceed · non-empty = error to show.
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: current, obscureText: true, decoration: const InputDecoration(labelText: 'Current password')),
            TextField(controller: next, obscureText: true, decoration: const InputDecoration(labelText: 'New password')),
            TextField(controller: confirm, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm new password')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (next.text.length < 6) {
                Navigator.pop(context, 'New password must be at least 6 characters');
                return;
              }
              if (next.text != confirm.text) {
                Navigator.pop(context, 'New passwords do not match');
                return;
              }
              Navigator.pop(context, '');
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return; // cancelled
    if (result.isNotEmpty) {
      _snack(result);
      return;
    }
    final outcome = await AuthStore.instance.changePassword(
      currentPassword: current.text,
      newPassword: next.text,
    );
    _snack(outcome ?? 'Password changed.');
  }

  Future<void> _changePasscode(BuildContext context) async {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    // Dialog result: null = cancelled · '' = proceed · non-empty = error to show.
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change signature passcode'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: current, obscureText: true, decoration: const InputDecoration(labelText: 'Current passcode')),
            TextField(controller: next, obscureText: true, decoration: const InputDecoration(labelText: 'New passcode')),
            TextField(controller: confirm, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm new passcode')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (next.text.length < 4) {
                Navigator.pop(context, 'Signature passcode must be at least 4 characters');
                return;
              }
              if (next.text != confirm.text) {
                Navigator.pop(context, 'New passcodes do not match');
                return;
              }
              Navigator.pop(context, '');
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return; // cancelled
    if (result.isNotEmpty) {
      _snack(result);
      return;
    }
    final outcome = await AuthStore.instance.changePasscode(
      currentPasscode: current.text,
      newPasscode: next.text,
    );
    _snack(outcome ?? 'Signature passcode changed.');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Widget _serialRow(BuildContext context, String type, String label, int bookSeed) {
    final controller = TextEditingController(text: '${SerialService.instance.current(type)}');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        SizedBox(width: 140, child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
        Expanded(
          child: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(hintText: 'book started at $bookSeed', isDense: true),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: () async {
            final v = int.tryParse(controller.text);
            if (v == null || v < 1) return;
            await AppStore.instance.updateSettings(serialReseed: {type: v});
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('Next $label will be numbered ${v + 1} — continues the book.')));
              setState(() {});
            }
          },
          child: const Text('Set'),
        ),
      ]),
    );
  }

  Future<void> _importTsv() async {
    if (_tsv.text.trim().isEmpty) {
      _setMsg('Paste the TXT contents first (or load the bundled seed).');
      return;
    }
    final added = await AppStore.instance.importSeedCsv(_tsv.text);
    _setMsg('Import complete — $added new products, ${AppStore.instance.products.length} total in stock.');
  }

  void _setMsg(String m) => setState(() => _importMsg = m);
}

/// ACCOUNT → RECOVERY — two self-service flows (owner directive 2026-09-01):
///   1. Reset the account password (and optionally the signature passcode)
///      using the recovery string chosen at sign-up.
///   2. Rotate the recovery string itself using the password + passcode.
/// There is deliberately NO email/OTP flow.
class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen({super.key});

  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final email = AuthStore.instance.current?.email ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('Recovery')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Account recovery',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Mtek.ink)),
          const SizedBox(height: 4),
          const Text(
            'Use the recovery string you chose at sign-up to reset a forgotten '
            'password — or reset the recovery string itself using your current '
            'password and signature passcode.',
            style: TextStyle(color: Mtek.gray500)),
          const SizedBox(height: 16),
          _resetPasswordCard(email),
          const SizedBox(height: 14),
          _resetRecoveryCard(email),
        ],
      ),
    );
  }

  Widget _resetPasswordCard(String email) {
    final emailC = TextEditingController(text: email);
    final recoveryC = TextEditingController();
    final passC = TextEditingController();
    final passcodeC = TextEditingController();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('RESET PASSWORD & PASSCODE',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1, color: Mtek.gray500)),
            const SizedBox(height: 10),
            TextField(controller: emailC, decoration: const InputDecoration(labelText: 'Account email')),
            TextField(controller: recoveryC, decoration: const InputDecoration(labelText: 'Recovery string')),
            TextField(controller: passC, obscureText: true, decoration: const InputDecoration(labelText: 'New password (min 6 characters)')),
            TextField(controller: passcodeC, obscureText: true, decoration: const InputDecoration(labelText: 'New signature passcode (optional, min 4 characters)')),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.lock_reset, size: 18),
              label: const Text('Reset password'),
              onPressed: _busy ? null : () => _doResetPassword(emailC, recoveryC, passC, passcodeC),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resetRecoveryCard(String email) {
    final emailC = TextEditingController(text: email);
    final passC = TextEditingController();
    final passcodeC = TextEditingController();
    final newRecoveryC = TextEditingController();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('RESET RECOVERY STRING',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1, color: Mtek.gray500)),
            const SizedBox(height: 10),
            TextField(controller: emailC, decoration: const InputDecoration(labelText: 'Account email')),
            TextField(controller: passC, obscureText: true, decoration: const InputDecoration(labelText: 'Current password')),
            TextField(controller: passcodeC, obscureText: true, decoration: const InputDecoration(labelText: 'Signature passcode')),
            TextField(controller: newRecoveryC, decoration: const InputDecoration(labelText: 'New recovery string (min 15 characters)')),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.key_outlined, size: 18),
              label: const Text('Reset recovery string'),
              onPressed: _busy ? null : () => _doResetRecovery(emailC, passC, passcodeC, newRecoveryC),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _doResetPassword(TextEditingController emailC, TextEditingController recoveryC,
      TextEditingController passC, TextEditingController passcodeC) async {
    if (recoveryC.text.trim().isEmpty) return _fail('Enter your recovery string.');
    if (passC.text.length < 6) return _fail('New password must be at least 6 characters.');
    final passcode = passcodeC.text.trim();
    if (passcode.isNotEmpty && passcode.length < 4) {
      return _fail('Signature passcode must be at least 4 characters.');
    }
    setState(() => _busy = true);
    final result = await AuthStore.instance.resetPasswordWithRecovery(
      email: emailC.text,
      recoveryString: recoveryC.text,
      newPassword: passC.text,
      newSignaturePasscode: passcode.isEmpty ? null : passcode,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    result == null ? _ok('Password reset — sign in with the new password.') : _fail(result);
  }

  Future<void> _doResetRecovery(TextEditingController emailC, TextEditingController passC,
      TextEditingController passcodeC, TextEditingController newRecoveryC) async {
    if (passC.text.isEmpty) return _fail('Enter your current password.');
    if (passcodeC.text.isEmpty) return _fail('Enter your signature passcode.');
    if (newRecoveryC.text.length < 15) return _fail('New recovery string must be at least 15 characters.');
    setState(() => _busy = true);
    final result = await AuthStore.instance.resetRecovery(
      email: emailC.text,
      password: passC.text,
      signaturePasscode: passcodeC.text,
      newRecoveryString: newRecoveryC.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    result == null ? _ok('Recovery string updated — keep it safe.') : _fail(result);
  }

  void _ok(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(backgroundColor: Mtek.success, content: Text(msg)));
  }

  void _fail(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
