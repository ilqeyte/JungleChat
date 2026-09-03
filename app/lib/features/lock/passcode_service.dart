import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Phase 4 — local passcode (6-digit PIN) storage and verification.
///
/// The PIN is NEVER stored. Only a PBKDF2-HMAC-SHA256 verifier (random salt +
/// hash, >=100k iterations) lives in the OS credential store (Android Keystore
/// / iOS Keychain via flutter_secure_storage). Biometric unlock is a convenience
/// alias over the same verifier and is never the sole credential — a PIN must be
/// set first, and biometric failure falls back to the PIN.
class PasscodeService {
  PasscodeService._();
  static final PasscodeService instance = PasscodeService._();

  // Default iOS accessibility (first unlock) is the correct posture for a
  // PIN verifier — keep the constructor version-agnostic rather than pin a
  // flutter_secure_storage enum name that changes across releases.
  static const _storage = FlutterSecureStorage();
  static const _pinHashKey = 'passcode.verifier';
  static const _pinSaltKey = 'passcode.salt';
  static const _attemptsKey = 'passcode.failed_attempts';

  static const iterations = 120000;

  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> isPinSet() async {
    final v = await _storage.read(key: _pinHashKey);
    return v != null && v.isNotEmpty;
  }

  Future<bool> get canAuthenticateBiometric async {
    try {
      return await _auth.canCheckBiometrics &&
          (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> setPin(String pin) async {
    _assertPin(pin);
    final salt = _randomBytes(16);
    final hash = _pbkdf2(utf8.encode(pin), salt, iterations, 32);
    await _storage.write(key: _pinSaltKey, value: base64Encode(salt));
    await _storage.write(key: _pinHashKey, value: base64Encode(hash));
    await _storage.write(key: _attemptsKey, value: '0');
  }

  Future<bool> verifyPin(String pin) async {
    final saltB64 = await _storage.read(key: _pinSaltKey);
    final hashB64 = await _storage.read(key: _pinHashKey);
    if (saltB64 == null || hashB64 == null) return false;
    final expected = base64Decode(hashB64);
    final actual = _pbkdf2(utf8.encode(pin), base64Decode(saltB64), iterations, 32);
    if (expected.length != actual.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected[i] ^ actual[i];
    }
    return diff == 0;
  }

  Future<void> clear() async {
    await _storage.delete(key: _pinHashKey);
    await _storage.delete(key: _pinSaltKey);
    await _storage.delete(key: _attemptsKey);
  }

  Future<bool> authenticateBiometric({
    String reason = 'Unlock JungleChat',
  }) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  // ---- device-local brute-force defence ----
  Future<int> get failedAttempts async =>
      int.tryParse(await _storage.read(key: _attemptsKey) ?? '0') ?? 0;

  Future<int> recordFailureAndGet() async {
    final n = await failedAttempts + 1;
    await _storage.write(key: _attemptsKey, value: n.toString());
    return n;
  }

  Future<void> resetFailures() async =>
      _storage.write(key: _attemptsKey, value: '0');

  static void _assertPin(String pin) {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw ArgumentError('PIN must be exactly 6 digits');
    }
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  /// PBKDF2-HMAC-SHA256, dkLen bytes, [iterations] passes. crypto has no built-in
  /// PBKDF2, so we build it from HMAC-SHA256 (constant-time per block).
  static Uint8List _pbkdf2(
    List<int> password,
    Uint8List salt,
    int iterations,
    int dkLen,
  ) {
    final hmac = Hmac(sha256, password);
    final out = <int>[];
    final blockCount = (dkLen + 31) ~/ 32; // SHA-256 → 32 bytes/block
    for (var i = 1; i <= blockCount; i++) {
      final msg = Uint8List(salt.length + 4);
      msg.setRange(0, salt.length, salt);
      msg[salt.length] = (i >> 24) & 0xff;
      msg[salt.length + 1] = (i >> 16) & 0xff;
      msg[salt.length + 2] = (i >> 8) & 0xff;
      msg[salt.length + 3] = i & 0xff;
      var d = hmac.convert(msg);
      var f = List<int>.from(d.bytes);
      for (var j = 1; j < iterations; j++) {
        d = hmac.convert(d.bytes);
        for (var k = 0; k < f.length; k++) {
          f[k] ^= d.bytes[k];
        }
      }
      out.addAll(f);
    }
    return Uint8List.fromList(out.sublist(0, dkLen));
  }
}
