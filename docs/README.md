# JungleChat

Anonymous, ephemeral chat. No name, no face, no phone number — users pick an
animal and start talking. Messages auto-delete, reactions are built in, and an
optional app-lock protects the device.

This repository is the complete, white-label source: a Flutter mobile app
(Android + iOS), a Flutter **Web** admin panel, and a Supabase backend
(database + Row-Level Security + Edge Functions).

## What's inside

| Path        | What it is                                                        |
|-------------|-------------------------------------------------------------------|
| `app/`      | Flutter mobile app (Android + iOS).                              |
| `admin/`    | Flutter Web admin panel (secure, MFA-protected).                 |
| `supabase/` | Migrations + Edge Functions for the Supabase backend.            |
| `docs/`     | This documentation.                                              |
| `.github/`  | GitHub Actions CI (APK, IPA, Supabase deploy).                   |

## Highlights

- **Anonymous by design.** Accounts are an animal + a recovery credential. No
  email, no phone, no profile photo. Privacy is structural, not a setting.
- **Server-authorized, deny-by-default.** Every write goes through a
  `SECURITY DEFINER` RPC. Clients never touch tables directly. Private DMs are
  unreachable by moderators — the schema makes it impossible.
- **MFA-protected admin.** The web admin requires an email + password **and**
  a TOTP second factor (aal2) before any privileged action.
- **White-label ready.** App name, tagline, brand colors, support contacts and
  feature toggles are editable from the admin panel and/or config files.
- **CI builds.** APK and IPA build from GitHub Actions; backend deploys with one
  command.

## Quick start

1. **Backend** — see `docs/DEPLOY.md` (link a Supabase project, push
   migrations, deploy the two Edge Functions).
2. **Mobile app** — `cd app && flutter pub get && flutter run`.
3. **Admin panel** — `cd admin && flutter pub get && flutter run -d chrome`.
   See `docs/ADMIN.md` for the admin bootstrap (you must grant one auth user
   the admin role).

## Documentation

- `docs/ADMIN.md` — run, deploy and operate the web admin panel.
- `docs/WHITE_LABEL.md` — rebrand and white-label the product.
- `docs/DEPLOY.md` — backend, app and CI deployment.
