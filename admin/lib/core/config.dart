/// JungleChat Admin — backend connection.
///
/// These values point at the SAME Supabase project the mobile app uses. The
/// publishable (anon) key is safe to ship in a web bundle: every privileged
/// action is gated server-side by `private.is_admin()` (admin_roles row +
/// MFA-elevated aal2 session), so the anon key grants nothing on its own.
///
/// To white-label / re-point the panel at a different project, change these
/// two constants and rebuild (`flutter build web`). See docs/ADMIN.md.
const String supabaseUrl = 'https://ndvdrpmrdifcakjbbbjy.supabase.co';
const String supabaseAnonKey =
    'sb_publishable_iJW8L2DCBE68UI4d8rpyVg_hqnMgA5i';
