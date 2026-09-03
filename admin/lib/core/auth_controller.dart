import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum AuthStatus { loading, unauthenticated, needsMfa, nonAdmin, authorized }

class AuthState {
  final AuthStatus status;
  final String? email;

  /// Existing TOTP factor id, present when the admin has already enrolled MFA
  /// and only needs to verify a code on this sign-in.
  final String? factorId;

  /// True when the admin has no MFA factor yet and must enroll one.
  final bool enrolling;

  const AuthState(
    this.status, {
    this.email,
    this.factorId,
    this.enrolling = false,
  });
}

/// Owns the sign-in → MFA → admin-authorization flow.
///
/// Security model (must match the database gate `private.is_admin()`):
///   1. Password sign-in yields an aal1 session.
///   2. We then require a TOTP challenge to reach aal2.
///   3. Only with aal2 do we call `is_current_user_admin()`, which checks the
///      caller's id is in `public.admin_roles`. Anything else is rejected.
class AuthController extends Notifier<AuthState> {
  SupabaseClient get _sb => Supabase.instance.client;

  @override
  AuthState build() => const AuthState(AuthStatus.loading);

  Future<void> init() async {
    final session = _sb.auth.currentSession;
    if (session == null) {
      state = const AuthState(AuthStatus.unauthenticated);
      return;
    }
    await _evaluate(session);
  }

  Future<void> _evaluate(Session? session) async {
    if (session == null) {
      state = const AuthState(AuthStatus.unauthenticated);
      return;
    }
    final aal = _sb.auth.mfa.getAuthenticatorAssuranceLevel();
    if (aal.currentLevel != AuthenticatorAssuranceLevels.aal2) {
      final factors = await _sb.auth.mfa.listFactors();
      final hasTotp = factors.totp.isNotEmpty;
      state = AuthState(
        AuthStatus.needsMfa,
        email: session.user.email,
        factorId: hasTotp ? factors.totp.first.id : null,
        enrolling: !hasTotp,
      );
      return;
    }
    final isAdmin =
        await _sb.rpc('is_current_user_admin') as bool? ?? false;
    state = AuthState(isAdmin ? AuthStatus.authorized : AuthStatus.nonAdmin);
  }

  Future<void> signIn(String email, String password) async {
    final res = await _sb.auth.signInWithPassword(
      email: email,
      password: password,
    );
    await _evaluate(res.session);
  }

  /// Called by the MFA page after a successful TOTP verify.
  Future<void> evaluateAfterMfa() async {
    await _evaluate(_sb.auth.currentSession);
  }

  Future<void> signOut() async {
    await _sb.auth.signOut();
    state = const AuthState(AuthStatus.unauthenticated);
  }
}

final authControllerProvider =
    NotifierProvider<AuthController, AuthState>(AuthController.new);
