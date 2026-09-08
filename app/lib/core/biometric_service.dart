import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

class BiometricService {
  BiometricService._();
  static final instance = BiometricService._();
  final _auth = LocalAuthentication();
  static const _storage = FlutterSecureStorage();

  Future<bool> available() async {
    try { return await _auth.isDeviceSupported() && await _auth.canCheckBiometrics; }
    catch (_) { return false; }
  }

  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason,
        options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true));
    } catch (_) { return false; }
  }

  Future<void> saveLogin(String email, String password) async {
    await _storage.write(key: 'bio_email', value: email);
    await _storage.write(key: 'bio_password', value: password);
  }
  Future<(String, String)?> login() async {
    if (!await authenticate('Sign in to MFSL Inventory')) return null;
    final e = await _storage.read(key: 'bio_email'), p = await _storage.read(key: 'bio_password');
    return e == null || p == null ? null : (e, p);
  }
  Future<void> saveSignaturePasscode(String value) => _storage.write(key: 'bio_signature', value: value);
  Future<String?> signaturePasscode() async =>
      await authenticate('Authorise your MFSL signature') ? _storage.read(key: 'bio_signature') : null;
  Future<void> clear() => _storage.deleteAll();
}
