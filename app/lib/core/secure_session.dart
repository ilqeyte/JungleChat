import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Session persistence backed by the platform secure storage
/// (Keychain / Keystore via flutter_secure_storage).
///
/// PRD §46: tokens must never sit in SharedPreferences or plaintext files.
class SecureSessionStorage extends LocalStorage {
  static const _key = 'in_supabase_session_v1';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async => await _storage.read(key: _key) != null;

  @override
  Future<String?> accessToken() => _storage.read(key: _key);

  @override
  Future<void> persistSession(String encryptedSession) async {
    await _storage.write(key: _key, value: encryptedSession);
  }

  @override
  Future<void> removePersistedSession() async {
    await _storage.delete(key: _key);
  }
}
