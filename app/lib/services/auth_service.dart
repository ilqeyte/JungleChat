import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config.dart';

/// The public identity card. Contains ONLY what the product is allowed to
/// show: animal kind, display Animal ID, discovery state (PRD Â§17).
class AnimalCard {
  final String id;
  final String animal;
  final String displayAnimalId;
  final bool openToTalk;
  final String? bio;
  final bool isOnline;

  const AnimalCard({
    required this.id,
    required this.animal,
    required this.displayAnimalId,
    required this.openToTalk,
    this.bio,
    this.isOnline = false,
  });

  factory AnimalCard.fromJson(Map<String, dynamic> j) => AnimalCard(
    id: j['id'] as String,
    animal: j['animal'] as String? ?? '',
    displayAnimalId: j['display_animal_id'] as String? ?? '',
    openToTalk: j['open_to_talk'] as bool? ?? true,
    bio: j['bio'] as String?,
    isOnline: j['is_online'] as bool? ?? false,
  );
}

class MyProfile {
  final String id;
  final String animal;
  final String displayAnimalId;
  final bool openToTalk;
  final bool randomTalkEnabled;
  final bool typingIndicatorEnabled;
  final bool inAppAlerts;
  final bool hapticsEnabled;
  final bool visibilityOnline;
  final String? bio;
  final bool isOnline;
  final int daysUntilDelete;

  const MyProfile({
    required this.id,
    required this.animal,
    required this.displayAnimalId,
    required this.openToTalk,
    required this.randomTalkEnabled,
    required this.typingIndicatorEnabled,
    required this.inAppAlerts,
    required this.hapticsEnabled,
    required this.visibilityOnline,
    this.bio,
    required this.isOnline,
    required this.daysUntilDelete,
  });

  factory MyProfile.fromJson(Map<String, dynamic> j) => MyProfile(
    id: j['id'] as String,
    animal: j['animal'] as String? ?? '',
    displayAnimalId: j['display_animal_id'] as String? ?? '',
    openToTalk: j['open_to_talk'] as bool? ?? true,
    randomTalkEnabled: j['random_talk_enabled'] as bool? ?? true,
    typingIndicatorEnabled: j['typing_indicator_enabled'] as bool? ?? true,
    inAppAlerts: j['in_app_alerts'] as bool? ?? true,
    hapticsEnabled: j['haptics_enabled'] as bool? ?? true,
    visibilityOnline: j['visibility_online'] as bool? ?? true,
    bio: j['bio'] as String?,
    isOnline: j['is_online'] as bool? ?? false,
    daysUntilDelete: (j['days_until_delete'] as num?)?.toInt() ?? 90,
  );
}

class AccountCreated {
  final String userId;
  final String animalId;
  final String recoveryCredential;

  const AccountCreated({
    required this.userId,
    required this.animalId,
    required this.recoveryCredential,
  });
}

/// Authentication flows.
///
/// SECURITY: credential verification happens exclusively server-side
/// (Edge Functions + SQL). This client only forwards input and handles the
/// uniform outcomes.
class AuthService {
  final SupabaseClient _db = Supabase.instance.client;

  /// Creates an anonymous account through the trusted Edge Function.
  /// The recovery credential is returned ONCE by the server; we never store it.
  Future<AccountCreated> createAccount(String animal) async {
    final res = await http.post(
      Uri.parse(AppConfig.createAccountFunction),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'animal': animal}),
    );

    if (res.statusCode == 429) throw Exception('code=RATE_LIMITED');
    if (res.statusCode != 200) throw Exception('code=ACCOUNT_CREATION_FAILED');

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return AccountCreated(
      userId: body['userId'] as String,
      animalId: body['animalId'] as String,
      recoveryCredential: body['recoveryCredential'] as String,
    );
  }

  /// Logs in via Edge Function which mints a normal Supabase session
  /// against the internal (hidden) identity. Failures are uniform.
  /// The secret may be the recovery credential (any casing) OR the login
  /// password (case-sensitive) ” the server tries both; we send it RAW.
  Future<void> login(String animalId, String secret) async {
    final res = await http.post(
      Uri.parse(AppConfig.loginFunction),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'animalId': animalId.toUpperCase().trim(),
        'credential': secret.trim(),
      }),
    );

    if (res.statusCode != 200) {
      throw Exception(
        res.statusCode == 429
            ? 'code=RATE_LIMITED'
            : 'code=INVALID_CREDENTIALS',
      );
    }

    final sessionJson =
        (jsonDecode(res.body) as Map<String, dynamic>)['session']
            as Map<String, dynamic>;
    // gotrue signature: setSession(refreshToken, {accessToken}) ” the
    // refresh token goes FIRST. Passing the access token here creates a
    // broken session (the bug that blocked entry after signup).
    await _db.auth.setSession(
      sessionJson['refresh_token'] as String,
      accessToken: sessionJson['access_token'] as String,
    );
  }

  Future<void> logout() => _db.auth.signOut();

  /// Sets/changes the login password. Current secret may be the recovery
  /// credential OR the existing password (reauthentication).
  Future<void> setLoginPassword({
    required String currentSecret,
    required String newPassword,
  }) {
    return _db.rpc(
      'service_set_login_password',
      params: {
        'p_current_secret': currentSecret,
        'p_new_password': newPassword,
      },
    );
  }

  /// Master-key reset: recovery credential proves identity, new password is
  /// set, and a fresh session is returned (auto-login).
  Future<void> resetPassword({
    required String animalId,
    required String credential,
    required String newPassword,
  }) async {
    final res = await http.post(
      Uri.parse('${AppConfig.supabaseUrl}/functions/v1/reset-password'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'animalId': animalId.toUpperCase().trim(),
        'credential': credential.toUpperCase().replaceAll(' ', ''),
        'newPassword': newPassword,
      }),
    );

    if (res.statusCode == 400) throw Exception('code=INVALID_PASSWORD');
    if (res.statusCode != 200) {
      throw Exception(
        res.statusCode == 429 ? 'code=RATE_LIMITED' : 'code=RESET_FAILED',
      );
    }

    final sessionJson =
        (jsonDecode(res.body) as Map<String, dynamic>)['session']
            as Map<String, dynamic>;
    // gotrue signature: setSession(refreshToken, {accessToken}) ” the
    // refresh token goes FIRST. Passing the access token here creates a
    // broken session (the bug that blocked entry after signup).
    await _db.auth.setSession(
      sessionJson['refresh_token'] as String,
      accessToken: sessionJson['access_token'] as String,
    );
  }

  Future<MyProfile?> fetchMyProfile() async {
    final rows = await _db.rpc('get_my_profile');
    if (rows is! List || rows.isEmpty) return null;
    return MyProfile.fromJson(Map<String, dynamic>.from(rows.first));
  }

  /// Changes the animal species, keeping the same number. The new identity
  /// is immediately discoverable by everyone. Rate-limited server-side
  /// (3 changes per 7 days).
  Future<String> changeAnimal(String newAnimal) async {
    return await _db.rpc(
      'change_my_animal',
      params: {'p_new_animal': newAnimal},
    ) as String;
  }

  /// Open to Talk / Mine Mode enforced server-side via RPC.
  Future<void> updateSettings({
    bool? openToTalk,
    bool? randomTalk,
    bool? typingIndicator,
    bool? inAppAlerts,
    bool? haptics,
    bool? visibilityOnline,
    String? bio,
  }) {
    return _db.rpc(
      'update_my_settings',
      params: {
        'p_open_to_talk': openToTalk,
        'p_random_talk': randomTalk,
        'p_typing_indicator': typingIndicator,
        'p_in_app_alerts': inAppAlerts,
        'p_haptics_enabled': haptics,
        'p_visibility_online': visibilityOnline,
        'p_bio': bio,
      },
    );
  }

  /// Phase 6: set THIS account's default disappearing-message interval.
  /// Applies to every NEW conversation/group going forward; existing threads
  /// keep their own timer. `null` turns it off. Server validates the value.
  Future<void> setDefaultAutoDelete(String? interval) => _db.rpc(
    'set_my_default_auto_delete',
    params: {'p_interval': interval},
  );

  /// Phase 6: read THIS account's default disappearing-message interval
  /// (e.g. "24 hours" / "7 days" / null). Seeds the Mine settings tile.
  Future<String?> getCurrentDefaultAutoDelete() async {
    final result = await _db.rpc('get_my_default_auto_delete');
    return result as String?;
  }
}
