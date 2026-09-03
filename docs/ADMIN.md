# JungleChat Admin Panel

A Flutter **Web** application for operating JungleChat: moderating reports,
managing users, running official support, shipping app updates, curating public
rooms, reviewing the audit log, and editing white-label branding.

It talks to the **same Supabase project** as the mobile app. The publishable
(anon) key is safe to ship in the web bundle because every privileged action is
gated server-side (see *Security model* below).

## Security model

Two layers protect the admin surface:

1. **Database gate (`private.is_admin()`).** Every `admin_*` RPC checks that the
   caller's user id exists in `public.admin_roles` **and** that the session has
   an MFA-elevated assurance level (`aal2` in the JWT). A stolen password alone
   cannot pass.
2. **Application gate.** The panel refuses to show any admin screen until the
   session is `aal2` *and* `is_current_user_admin()` returns true.

Private direct messages are **not** exposed to admins. Reports about a public
message can be actioned; the underlying private conversations are structurally
unreachable by the moderation queries.

## Run locally

```bash
cd admin
flutter pub get
flutter run -d chrome
```

Requires Flutter 3.47.0 (the version this repo targets). Use `flutter channel
stable` and `flutter upgrade` if needed.

## Build for production

```bash
cd admin
flutter build web --release
```

The output is a static site in `admin/build/web`. Host it on any static host:
Cloudflare Pages, Netlify, Firebase Hosting, GitHub Pages, or an S3 bucket.

### Example: Cloudflare Pages

- Build command: `flutter build web --release`
- Build output directory: `build/web`
- No environment variables or build-time secrets are required.

### Example: Firebase Hosting

```bash
npm i -g firebase-tools
flutter build web --release
firebase init hosting   # set public dir to build/web, SPA-style rewrites
firebase deploy
```

## Admin bootstrap (required once)

The migrations create the `admin_roles` table but do **not** create an admin —
that would hardcode a credential. You grant admin to an existing auth user.

1. **Create the admin auth account.** In the Supabase dashboard → *Authentication
   → Users → Add user*, or have the owner sign up. Use a real email + strong
   password. (Email confirmation can be skipped for an internal admin.)
2. **Grant the admin role.** Run this SQL in the Supabase dashboard → *SQL
   Editor* (replace the email):

   ```sql
   insert into public.admin_roles (user_id)
   select id from auth.users where email = 'you@yourdomain.com'
   on conflict (user_id) do nothing;
   ```

That's it. The user now signs in with email + password and is prompted to enroll
a TOTP authenticator (Google Authenticator / Authy / 1Password) on first login.

> To grant more admins later, repeat step 2 for their auth user. To revoke,
> `delete from public.admin_roles where user_id = (select id from auth.users
> where email = '...');`.

## First sign-in (MFA enrollment)

1. Open the admin panel URL.
2. Sign in with the admin email + password.
3. You'll be taken to the **two-factor** screen. Scan the QR code with your
   authenticator app and enter the 6-digit code.
4. You land on the Dashboard. The TOTP factor stays enrolled; future sign-ins
   only ask for the code.

Returning admins who already enrolled skip straight to the code prompt.

## Sections

| Section     | What you can do                                                      |
|-------------|----------------------------------------------------------------------|
| Dashboard   | User / open-report / support counts and recent admin activity.      |
| Users       | List accounts; set active / mute / suspend / ban; soft-delete (7-day undo). |
| Reports     | Review reports; resolve (investigating/resolved/dismissed); view and remove the reported **public** message. |
| Support     | Open and reply in the official support channel with any user.       |
| Updates     | Create, publish, set-active, require, and delete app updates (APK URL). |
| Rooms       | Create / edit / delete built-in public rooms.                       |
| Audit       | Read-only trail of every moderation action (who / what / when).     |
| White-label | Edit app name, tagline, brand colors, support contacts, feature toggles. |

## Re-pointing the panel at a different project

Edit `admin/lib/core/config.dart`:

```dart
const String supabaseUrl = 'https://<your-project>.supabase.co';
const String supabaseAnonKey = '<your publishable key>';
```

then `flutter build web --release` again. The panel and the mobile app must
point at the **same** project.

## Troubleshooting

- **"Not an administrator" screen** → the signed-in user is not in
  `admin_roles`. Run the bootstrap SQL above.
- **Stuck on the code prompt** → the TOTP factor was never enrolled, or the
  authenticator clock is off. Re-enroll from the auth provider if needed.
- **RPC errors in the browser console** → confirm the migrations are fully
  applied (`supabase db push`) and the user is `aal2`.
