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

> **Never create auth users with SQL.** On the current Supabase platform the
> auth service does not read rows inserted directly into `auth.users` — such
> users can never sign in, and password hashes written via SQL are ignored.
> Always use the dashboard's *Add user*, the script below, or the Auth Admin
> API.

1. **Create the admin auth account.** In the Supabase dashboard → *Authentication
   → Users → Add user*. Use a real email + strong password. (Email confirmation
   can be skipped for an internal admin.)
2. **Grant the admin role.** Run this SQL in the Supabase dashboard → *SQL
   Editor* (replace the email):

   ```sql
   insert into public.admin_roles (user_id)
   select id from auth.users where email = 'you@yourdomain.com'
   on conflict (user_id) do nothing;
   ```

That's it. The user now signs in with email + password and is prompted to enroll
a TOTP authenticator (Google Authenticator / Authy / 1Password) on first login.

**Or do both steps with one command** — `scripts/bootstrap_admin.py` creates
(or finds) the user, resets the password to the one you pass, and grants the
role (idempotent). It needs the project URL and a secret key from
*Project Settings → API Keys* (read from the environment, never hardcoded):

```bash
SUPABASE_SECRET_KEY=sb_secret_... python3 scripts/bootstrap_admin.py \
    --url https://your-project.supabase.co \
    --email admin@yourdomain.com \
    --password 'strong-password-here'
```

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

## Changing admin credentials (anytime, no redeploy)

There is **no default password** — credentials are whatever you set at
bootstrap. Password changes go through the **Auth Admin API** (Supabase's own
auth service hashes it — this is the only reliable method on the current
platform; SQL-written hashes are ignored). Role changes are plain SQL. Nothing
here requires rebuilding or redeploying the panel.

> **Where "admin" lives:** the admin is an ordinary row under
> *Authentication → Users* (e.g. `admin@yourdomain.com`). What makes that
> account an admin is a matching row in `public.admin_roles` (see it in *Table
> Editor → public → admin_roles*). There is no separate "Admin" section in the
> Supabase dashboard — the admin panel itself is the Flutter web app in
> `admin/` of this repo.

- **Change the admin password (easiest).** One-time setup: copy your secret key
  (`sb_secret_...` or the legacy `service_role` key) from *Project Settings →
  API Keys*. Then either re-run the bootstrap script (it resets the password of
  the given email), or call the Auth Admin API directly.

  PowerShell (Windows):

  ```powershell
  $headers = @{ "apikey" = "PASTE_SECRET_KEY"; "Authorization" = "Bearer PASTE_SECRET_KEY"; "Content-Type" = "application/json" }
  Invoke-RestMethod -Method Put -Uri "https://YOUR-PROJECT.supabase.co/auth/v1/admin/users/ADMIN-USER-ID" -Headers $headers -Body '{"password":"NEW_PASSWORD"}'
  ```

  curl (macOS / Linux):

  ```bash
  curl -X PUT "https://YOUR-PROJECT.supabase.co/auth/v1/admin/users/ADMIN-USER-ID" \
    -H "apikey: $SUPABASE_SECRET_KEY" -H "Authorization: Bearer $SUPABASE_SECRET_KEY" \
    -H "Content-Type: application/json" -d '{"password":"NEW_PASSWORD"}'
  ```

  Find the `ADMIN-USER-ID` in *Authentication → Users* (click the user) or with
  `select id from auth.users where email = 'you@yourdomain.com';` in the SQL
  Editor. Existing TOTP enrollment is unaffected; the new password works on the
  next sign-in.

- **Promote another user to admin.** SQL Editor:

  ```sql
  insert into public.admin_roles (user_id)
  select id from auth.users where email = 'new-admin@yourdomain.com'
  on conflict (user_id) do nothing;
  ```

- **Revoke an admin.** SQL Editor:

  ```sql
  delete from public.admin_roles where user_id = (
    select id from auth.users where email = 'ex-admin@yourdomain.com'
  );
  ```

- **Lost the authenticator phone (TOTP).** Delete the enrolled factor via the
  Auth Admin API — the next sign-in prompts for enrollment again with a fresh
  QR code. (Only do this from a trusted session — it temporarily weakens the
  second gate.) First list the user's factors to get the factor id:

  ```bash
  curl "https://YOUR-PROJECT.supabase.co/auth/v1/admin/users?per_page=100" \
    -H "apikey: $SUPABASE_SECRET_KEY" -H "Authorization: Bearer $SUPABASE_SECRET_KEY"
  # find your user, note the factor "id" in its "factors" array, then:
  curl -X DELETE "https://YOUR-PROJECT.supabase.co/auth/v1/admin/users/ADMIN-USER-ID/factors/FACTOR-ID" \
    -H "apikey: $SUPABASE_SECRET_KEY" -H "Authorization: Bearer $SUPABASE_SECRET_KEY"
  ```

- **Reset everything at once.** Bootstrap a brand-new admin (steps above, or
  `scripts/bootstrap_admin.py`), sign in once to verify, then delete the old
  auth user from *Authentication → Users*.

> Deleting a user from *Authentication → Users* does **not** remove their
> `admin_roles` row automatically; run the revoke SQL above as well.

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

- **"Invalid login credentials" even though you set the password via SQL** →
  SQL-written password hashes are ignored by the auth service. Use the Auth
  Admin API method above (or the bootstrap script).
- **User created via SQL cannot sign in at all** → the auth service does not
  see rows inserted directly into `auth.users`. Delete the ghost row and create
  the user through *Authentication → Users → Add user*, the Auth Admin API, or
  the bootstrap script.
- **"Not an administrator" screen** → the signed-in user is not in
  `admin_roles`. Run the bootstrap SQL above.
- **Stuck on the code prompt** → the TOTP factor was never enrolled, or the
  authenticator clock is off. Re-enroll from the auth provider if needed.
- **RPC errors in the browser console** → confirm the migrations are fully
  applied (`supabase db push`) and the user is `aal2`.
