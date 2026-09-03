/// JungleChat — client configuration.
///
/// SECURITY (PRD §41): ONLY the project URL and PUBLISHABLE key live here.
/// They are designed to be public. No service-role key, admin credential,
/// or any other privileged secret may ever be added to this file or to the
/// app bundle.
class AppConfig {
  AppConfig._();

  static const String supabaseUrl = 'https://ndvdrpmrdifcakjbbbjy.supabase.co';
  static const String supabasePublishableKey =
      'sb_publishable_iJW8L2DCBE68UI4d8rpyVg_hqnMgA5i';

  static const String createAccountFunction =
      '$supabaseUrl/functions/v1/create-account';
  static const String loginFunction = '$supabaseUrl/functions/v1/login';

  /// Server-side content limits mirrored here for UX feedback ONLY.
  /// The backend enforces the real limits regardless of what this client does.
  static const int maxMessageLength = 1000;
  static const int maxReportLength = 2000;
}
