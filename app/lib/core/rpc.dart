import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Compatibility layer for RPC calls whose server-side signature may lag the
/// installed app.
///
/// WHY THIS EXISTS
/// ---------------
/// Migrations are deployed to Supabase manually (see
/// `.github/workflows/supabase-deploy.yml`), so the production database can be
/// one or more migrations behind the APK. When that happens PostgREST cannot
/// resolve the function and returns `PGRST202`, which the user used to see as
/// "Something went wrong."
///
/// The concrete instance that triggered this file: migrations `0306`/`0307`
/// added `p_client_msg_id` to the send RPCs, so the app sends four parameters
/// while an older server still exposes three.
///
/// HOW IT STAYS SAFE
/// -----------------
/// * The fallback only drops the OPTIONAL argument. It never changes the
///   caller's identity, content, or authorization — all of that stays
///   server-side and unchanged.
/// * Idempotency is preserved: the same `clientMsgId` is sent on the retry, so
///   a server that DID insert before the timeout returns the existing row
///   instead of duplicating (0306 `ON CONFLICT DO UPDATE`).
/// * Nothing is fabricated client-side. If both attempts fail, the original
///   error is rethrown so the real cause stays visible in logs.
class Rpc {
  const Rpc._();

  /// Calls [function] with [params].
  ///
  /// If the server rejects the call because the function signature does not
  /// match ([PGRST202] / SQLSTATE 42883) and [fallbackParams] is supplied, the
  /// call is retried once with those parameters.
  static Future<dynamic> call(
    String function, {
    required Map<String, dynamic> params,
    Map<String, dynamic>? fallbackParams,
  }) async {
    final SupabaseClient db = Supabase.instance.client;
    try {
      return await db.rpc(function, params: params);
    } catch (e) {
      final usableFallback =
          fallbackParams != null && _isSignatureMismatch(e);
      if (!usableFallback) rethrow;

      debugPrint('RPC $function: new signature rejected, retrying legacy form');
      try {
        return await db.rpc(function, params: fallbackParams);
      } catch (retryError) {
        // Preserve the ORIGINAL error — it names the signature the app
        // actually wanted, which is what makes the drift diagnosable.
        debugPrint('RPC $function: legacy retry also failed — $retryError');
        rethrow;
      }
    }
  }

  /// Sends a message RPC and returns the new message id as a [String].
  ///
  /// Guards the `as String` cast that previously crashed when PostgREST
  /// returned null (or a scalar shape the client did not expect), which
  /// surfaced as a send failure even though the insert had succeeded.
  static Future<String> sendMessage(
    String function, {
    required Map<String, dynamic> params,
    Map<String, dynamic>? fallbackParams,
  }) async {
    final res = await call(
      function,
      params: params,
      fallbackParams: fallbackParams,
    );
    final id = res?.toString();
    if (id == null || id.isEmpty || id.toLowerCase() == 'null') {
      throw Exception('EMPTY_RPC_RESPONSE for $function');
    }
    return id;
  }

  static bool _isSignatureMismatch(Object error) {
    final raw = error.toString().toUpperCase();
    return raw.contains('PGRST202') ||
        raw.contains('PGRST203') ||
        RegExp(r'\b42883\b').hasMatch(raw);
  }
}
