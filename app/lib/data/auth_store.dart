import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'env.dart';
import 'local_store.dart';
import 'rest_client.dart';
import 'store.dart';

/// Staff accounts with TWO separate secrets:
///  • account password  → signs in
///  • signature passcode → authorises/signs documents (SPEC §6.1)
///
/// M1 demo hashing (fnv1a) — replaced in M3 by Supabase Auth + salted
/// hashes (staff.signature_passcode_hash) + signature images in Storage.
class StaffUser {
  final String name;
  final String email;
  String role; // 'ceo' | 'admin' | 'sales'
  final String passwordHash;
  final String signaturePasscodeHash;
  final String? signaturePng; // base64 data-URL of the drawn signature
  StaffUser({
    required this.name,
    required this.email,
    required this.role,
    required this.passwordHash,
    required this.signaturePasscodeHash,
    this.signaturePng,
  });

  Map<String, dynamic> toJson() => {
        'name': name, 'email': email, 'role': role,
        'passwordHash': passwordHash,
        'signaturePasscodeHash': signaturePasscodeHash,
        'signaturePng': signaturePng,
      };
  static StaffUser fromJson(Map<String, dynamic> j) => StaffUser(
        name: j['name'], email: j['email'], role: j['role'],
        passwordHash: j['passwordHash'],
        signaturePasscodeHash: j['signaturePasscodeHash'],
        signaturePng: j['signaturePng'],
      );
}

String demoHash(String input) {
  // FNV-1a 32-bit — DEMO ONLY (client-side, unsalted). M3 moves all
  // credential verification server-side with salted hashes.
  var h = 0x811c9dc5;
  for (final code in utf8.encode('mtek::$input')) {
    h ^= code;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

class AuthStore extends ChangeNotifier {
  AuthStore._() {
    // NO preset accounts (owner directive 2026-08-30): real sign-in happens
    // against Supabase Auth; the local directory fills from real sign-ins
    // and real Sign Ups only. The CEO identity is locked via [ceoEmail] and
    // is never registrable — it signs in with the owner's real credentials.
  }

  /// The CEO identity is fixed to this email across the whole system
  /// (Flutter app, preview server, Supabase backend in Phase C).
  static const String ceoEmail = 'mtekfiresafetyltd@gmail.com';
  static final AuthStore instance = AuthStore._();

  final List<StaffUser> users = [];
  StaffUser? current;

  bool get isSignedIn => current != null;
  bool get isAdmin => current?.role == 'admin';

  /// CEO outranks admin — full management reach everywhere.
  bool get isCeo => current?.role == 'ceo';

  /// Management-level authority (CEO or Admin): settings, seeds, approvals.
  bool get isManagement => isAdmin || isCeo;

  String? signIn(String email, String password) {
    if (users.isEmpty) {
      return 'No backend configured in this build — sign-in needs the M-TEK'
          ' Supabase settings. Accounts you create appear here.';
    }
    final mail = email.trim().toLowerCase();
    final user = users.where((u) => u.email == mail).firstOrNull;
    if (user == null) return 'No account with that email';
    if (user.passwordHash != demoHash(password)) return 'Wrong password';
    if (mail == ceoEmail && user.role != 'ceo') user.role = 'ceo'; // locked
    current = user;
    notifyListeners();
    return null;
  }

  /// Creates the account. Enforces password ≠ signature passcode.
  /// OFFLINE-ONLY fallback (no backend configured in this build) — kept so
  /// the app is still usable in a dev/demo checkout with no Supabase set up.
  /// The real, server-backed path is [remoteSignUp] below.
  String? signUp({
    required String name,
    required String email,
    required String password,
    required String signaturePasscode,
    required String role,
    String? signaturePng,
  }) {
    final mail = email.trim().toLowerCase();
    if (name.trim().isEmpty) return 'Enter your full name';
    if (!mail.contains('@')) return 'Enter a valid email';
    if (password.length < 6) return 'Password must be at least 6 characters';
    if (signaturePasscode.length < 4) {
      return 'Signature passcode must be at least 4 characters';
    }
    if (signaturePasscode == password) {
      return 'Signature passcode must be different from your password';
    }
    if (mail == ceoEmail) return 'The CEO account is pre-provisioned — sign in directly';
    if (users.any((u) => u.email == mail)) return 'An account with that email already exists';
    users.add(StaffUser(
      name: name.trim(),
      email: mail,
      role: role == 'ceo' ? 'admin' : role,
      passwordHash: demoHash(password),
      signaturePasscodeHash: demoHash(signaturePasscode),
      signaturePng: signaturePng,
    ));
    current = users.last;
    notifyListeners();
    return null;
  }

  /// REAL sign-up: creates an actual Supabase Auth user via the data API
  /// (which holds the service-role key server-side) then signs the new
  /// account straight in with a live session, exactly like [remoteSignIn].
  /// New self-signups always land as 'sales' — the server enforces this
  /// too, so nobody can grant themselves admin/CEO from this screen; only
  /// the CEO promotes staff afterwards from the in-app Staff screen (owner
  /// directive 2026-09-01). `phone` is set on the actual Supabase Auth user
  /// (shows up in Authentication → Users) and `recoveryString` (≥15 chars,
  /// chosen by the user) is the only way to reset a forgotten password —
  /// there is no email/OTP flow.
  Future<String?> remoteSignUp({
    required String name,
    required String email,
    required String phone,
    required String password,
    required String signaturePasscode,
    required String recoveryString,
  }) async {
    final api = AppStore.instance.api;
    if (!Env.apiConfigured || api == null) {
      return 'No backend configured in this build.';
    }
    final mail = email.trim().toLowerCase();
    final res = await api.postPublic('/api/auth/signup', {
      'name': name.trim(),
      'email': mail,
      'phone': phone.trim(),
      'password': password,
      'signature_passcode': signaturePasscode,
      'recovery_string': recoveryString,
    });
    if (res == null) return 'Network unreachable — check your connection';
    final j = res.json;
    if (!res.ok) {
      final msg = (j is Map ? j['error'] : null);
      return msg is String ? msg : 'Could not create the account — please try again.';
    }
    if (j is! Map || j['access_token'] is! String || j['user'] is! Map) {
      return 'Unexpected response from the server';
    }
    await _adoptSession(j);
    await AppStore.instance.reloadRemote();
    return null;
  }

  /// No-email, no-OTP password reset: the user proves ownership with the
  /// recovery phrase they set at sign-up (owner directive 2026-09-01).
  /// Pass [newSignaturePasscode] to also rotate the signature passcode in
  /// the same recovery flow (Settings → Account → Recovery).
  Future<String?> resetPasswordWithRecovery({
    required String email,
    required String recoveryString,
    required String newPassword,
    String? newSignaturePasscode,
  }) async {
    final api = AppStore.instance.api;
    if (!Env.apiConfigured || api == null) {
      return 'No backend configured in this build.';
    }
    final res = await api.postPublic('/api/auth/reset-password', {
      'email': email.trim().toLowerCase(),
      'recovery_string': recoveryString,
      'new_password': newPassword,
      if (newSignaturePasscode != null && newSignaturePasscode.isNotEmpty)
        'new_signature_passcode': newSignaturePasscode,
    });
    if (res == null) return 'Network unreachable — check your connection';
    if (!res.ok) {
      final msg = (res.json is Map ? (res.json as Map)['error'] : null);
      return msg is String ? msg : 'Could not reset the password';
    }
    return null;
  }

  /// Rotates the recovery phrase. Requires BOTH the account password and the
  /// signature passcode together — either alone is rejected server-side
  /// (Settings → Account → Recovery).
  Future<String?> resetRecovery({
    required String email,
    required String password,
    required String signaturePasscode,
    required String newRecoveryString,
  }) async {
    final api = AppStore.instance.api;
    if (!Env.apiConfigured || api == null) {
      return 'No backend configured in this build.';
    }
    final res = await api.postPublic('/api/auth/reset-recovery', {
      'email': email.trim().toLowerCase(),
      'password': password,
      'signature_passcode': signaturePasscode,
      'new_recovery_string': newRecoveryString,
    });
    if (res == null) return 'Network unreachable — check your connection';
    if (!res.ok) {
      final msg = (res.json is Map ? (res.json as Map)['error'] : null);
      return msg is String ? msg : 'Could not reset the recovery string';
    }
    return null;
  }

  /// Changes the account password while signed in (Settings → Account).
  /// Requires the current password; no email/OTP round-trip.
  Future<String?> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final api = AppStore.instance.api;
    if (!Env.apiConfigured || api == null || accessToken == null) {
      return 'You must be signed in to change your password.';
    }
    final res = await api.post('/api/auth/change-password', {
      'current_password': currentPassword,
      'new_password': newPassword,
    });
    if (res == null) return 'Network unreachable — check your connection';
    if (!res.ok) {
      final msg = (res.json is Map ? (res.json as Map)['error'] : null);
      return msg is String ? msg : 'Could not change the password';
    }
    return null;
  }

  /// Changes the signature passcode while signed in (Settings → Account).
  /// Requires the current passcode. Clears the in-RAM last-verified passcode
  /// so the next document sign forces a fresh bind against the new hash.
  Future<String?> changePasscode({
    required String currentPasscode,
    required String newPasscode,
  }) async {
    final api = AppStore.instance.api;
    if (!Env.apiConfigured || api == null || accessToken == null) {
      return 'You must be signed in to change your signature passcode.';
    }
    final res = await api.post('/api/auth/change-passcode', {
      'current_passcode': currentPasscode,
      'new_passcode': newPasscode,
    });
    if (res == null) return 'Network unreachable — check your connection';
    if (!res.ok) {
      final msg = (res.json is Map ? (res.json as Map)['error'] : null);
      return msg is String ? msg : 'Could not change the signature passcode';
    }
    lastVerifiedPasscode = null;
    return null;
  }

  /// Verifies the Signature Passcode when issuing a document (local/offline).
  bool verifySignature(String passcode) {
    final user = current;
    if (user == null) return false;
    return user.signaturePasscodeHash == demoHash(passcode);
  }

  /// The passcode last verified OK (kept in RAM only) — passed to the data
  /// API which re-verifies it against the stored hash in MongoDB.
  String? lastVerifiedPasscode;

  /// Real backend path: verify against the stored hash (scrypt) in
  /// MongoDB via the data API. Falls back to the local check only when the
  /// API is not configured or unreachable.
  Future<bool> verifySignatureAny(String passcode) async {
    final api = AppStore.instance.api;
    if (Env.apiConfigured && api != null && accessToken != null) {
      final res = await api.post('/api/auth/signature', {'passcode': passcode});
      if (res != null && res.ok) {
        lastVerifiedPasscode = passcode;
        return true;
      }
      if (res != null) return false; // server actively rejected
    }
    final ok = verifySignature(passcode);
    if (ok) lastVerifiedPasscode = passcode;
    return ok;
  }

  /// Real Supabase Auth sign-in. On success the RestClient carries the
  /// user's JWT so every read/write runs under RLS as that account, and
  /// the profile (name/role) comes from public.profiles.
  Future<String?> remoteSignIn(String email, String password) async {
    final remote = AppStore.instance.remote;
    if (!Env.backendConfigured || remote == null) return null; // caller falls back to local
    final mail = email.trim().toLowerCase();
    final res = await remote.authSignInRaw(mail, password);
    if (res == null) return 'Network unreachable — check your connection';
    final j = res.json;
    if (!res.ok) {
      final msg = (j is Map ? (j['error_description'] ?? j['error'] ?? j['msg']) : null);
      return msg is String ? msg : 'Sign-in failed — please try again.';
    }
    if (j is! Map || j['access_token'] is! String || j['user'] is! Map) {
      return 'Unexpected auth response';
    }
    await _adoptSession({
      'access_token': j['access_token'],
      'refresh_token': j['refresh_token'],
      'user': {'uid': j['user']['id'], 'email': mail},
    });
    // pull the live dataset from MongoDB for this account
    await AppStore.instance.reloadRemote();
    return null;
  }

  /// Common session bootstrap: stash the token(s), warm the role/name from
  /// /api/me, reconcile into the local directory, and PERSIST the session
  /// (access + refresh token) to disk so exiting the app never signs the
  /// user out (owner directive 2026-09-01). Used by sign-in, sign-up and
  /// the silent boot-time [restoreSession].
  Future<void> _adoptSession(Map j) async {
    final remote = AppStore.instance.remote;
    final api = AppStore.instance.api;
    final accessTok = '${j['access_token'] ?? ''}';
    final refreshTok = '${j['refresh_token'] ?? ''}';
    if (remote != null) remote.accessToken = accessTok;
    if (api != null) api.accessToken = accessTok;
    final u = (j['user'] as Map?) ?? const {};
    final uid = '${u['uid'] ?? u['id'] ?? ''}';
    final mail = '${u['email'] ?? ''}'.toLowerCase();
    String role = '${u['role'] ?? 'sales'}';
    String name = '${u['name'] ?? mail.split('@').first}';
    if (Env.apiConfigured && api != null && (u['role'] == null || u['name'] == null)) {
      final me = await api.get('/api/me');
      if (me != null && me.ok && me.json is Map) {
        final mu = (me.json as Map)['user'];
        if (mu is Map) {
          role = '${mu['role'] ?? role}';
          name = '${mu['name'] ?? name}';
        }
      }
    }
    remoteSignInUid = uid;
    users.removeWhere((x) => x.email == mail);
    users.add(StaffUser(
      name: name,
      email: mail,
      role: role,
      passwordHash: '',
      signaturePasscodeHash: '',
    ));
    current = users.last;
    notifyListeners();
    if (refreshTok.isNotEmpty) {
      await localWrite('session', jsonEncode({
        'access_token': accessTok,
        'refresh_token': refreshTok,
        'email': mail,
        'name': name,
        'role': role,
      }));
    }
  }

  /// Supabase auth.users id of the signed-in account (null offline).
  String? remoteSignInUid;

  /// Current Supabase JWT for data-API calls (null when signed out/offline).
  String? get accessToken => AppStore.instance.remote?.accessToken;

  /// Called once at boot (before the login screen would otherwise show):
  /// reads the refresh token saved by [_adoptSession] and silently exchanges
  /// it for a fresh access token, so closing/reopening the app keeps the
  /// user signed in (owner directive 2026-09-01 — previously every restart
  /// forced a fresh sign-in with no session saved anywhere).
  Future<void> restoreSession() async {
    final api = AppStore.instance.api;
    if (!Env.apiConfigured || api == null) return;
    final raw = await localRead('session');
    if (raw == null || raw.isEmpty) return;
    Map<String, dynamic> saved;
    try {
      saved = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final refreshTok = '${saved['refresh_token'] ?? ''}';
    if (refreshTok.isEmpty) return;
    final res = await api.postPublic('/api/auth/refresh', {'refresh_token': refreshTok});
    if (res == null) {
      // Offline at boot — sign back into the CACHED identity so the user
      // still lands in the app (working off the local data cache, same as
      // the rest of the app's offline-first design) instead of being
      // bounced to the login screen just because there's no connection
      // yet. A real refresh is retried the next time the app can reach it.
      _restoreCachedIdentity(saved);
      return;
    }
    final body = res.json;
    // Only a GENUINE auth rejection signs the user out: a 4xx response that
    // carries our own `error` field (e.g. the refresh token was revoked).
    // Everything else — a 5xx server fault, a malformed/empty body, a
    // 401/404/502 from a proxy — is treated as a TRANSIENT failure and must
    // NOT wipe the saved session (that was the regression: any hiccup
    // bounced users back to login and destroyed their session on disk).
    final isAuthReject = !res.ok &&
        res.status >= 400 &&
        res.status < 500 &&
        body is Map &&
        body['error'] is String;
    if (isAuthReject) {
      // refresh token genuinely expired/revoked — sign out cleanly.
      await localWrite('session', '');
      return;
    }
    if (res.ok && body is Map) {
      await _adoptSession(body);
      await AppStore.instance.reloadRemote();
      return;
    }
    // Transient (5xx, non-Map body, unexpected status) — keep the session
    // and fall back to the cached identity rather than signing the user out.
    _restoreCachedIdentity(saved);
  }

  /// Rehydrates the signed-in identity from the persisted session blob so
  /// the user lands in the app (offline-first, working off the local cache)
  /// even when the server can't be reached yet at boot.
  void _restoreCachedIdentity(Map<String, dynamic> saved) {
    final mail = '${saved['email'] ?? ''}';
    if (mail.isEmpty) return;
    users.removeWhere((x) => x.email == mail);
    users.add(StaffUser(
      name: '${saved['name'] ?? mail.split('@').first}',
      email: mail,
      role: '${saved['role'] ?? 'sales'}',
      passwordHash: '',
      signaturePasscodeHash: '',
    ));
    current = users.last;
    notifyListeners();
  }

  void signOut() {
    current = null;
    remoteSignInUid = null;
    AppStore.instance.remote?.accessToken = null;
    AppStore.instance.api?.accessToken = null;
    unawaited(localWrite('session', ''));
    notifyListeners();
  }

  /// Public notification for external listeners (boot/data-load events).
  void ping() => notifyListeners();
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
