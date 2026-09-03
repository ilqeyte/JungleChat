# Deployment

Three deployable surfaces: the **Supabase backend**, the **mobile app** (via
GitHub Actions), and the **web admin panel** (static host — see `docs/ADMIN.md`).

This repo's Supabase project reference is `ndvdrpmrdifcakjbbbjy`.

---

## 1. Supabase backend

### Prerequisites

- Supabase CLI: `npm i -g supabase` (or `brew install supabase/tap/supabase`).
- A Supabase project (free tier is fine).

### Link and push

```bash
cd supabase
supabase link --project-ref ndvdrpmrdifcakjbbbjy
supabase db push          # applies every migration in supabase/migrations/
```

`db push` is idempotent and ordered. If you ever need to apply migrations that
were skipped or reordered, use `supabase db push --include-all`.

### Deploy the Edge Functions

Two functions back account creation and login:

```bash
supabase functions deploy create-account
supabase functions deploy login
```

They rely on the reserved `SUPABASE_URL`, `SUPABASE_ANON_KEY` and
`SUPABASE_SERVICE_ROLE_KEY`, which Supabase injects automatically — **do not**
try to set those as secrets. No extra secrets are required for these two
functions.

### Verify

After deploy, confirm the app can create an account and sign in end-to-end
(see the SellMyApp walkthrough). You should also see the `app_config` seed rows
and be able to grant an admin (see `docs/ADMIN.md`).

---

## 2. Mobile app (GitHub Actions)

The workflows live in `.github/workflows/`:

- `build-apk.yml` — builds a release APK (and AAB) on every tag `v*`.
- `build-ios.yml` — builds a release IPA on macOS runners, on every tag `v*`.
- `supabase-deploy.yml` — pushes migrations + deploys the Edge Functions.

### Required repository secrets

| Secret                         | Used by            | Purpose                                  |
|--------------------------------|--------------------|------------------------------------------|
| `SUPABASE_ACCESS_TOKEN`        | supabase-deploy    | CLI auth (Personal Access Token).        |
| `SUPABASE_DB_PASSWORD`         | supabase-deploy    | Database password for `db push`.         |
| `KEYSTORE_BASE64`              | build-apk          | Base64 of your upload keystore (jks).    |
| `KEYSTORE_PASSWORD`            | build-apk          | Keystore password.                       |
| `KEY_ALIAS`                    | build-apk          | Key alias.                              |
| `KEY_PASSWORD`                 | build-apk          | Key password.                           |
| `APPLE_DIST_CERT_BASE64`       | build-ios          | Base64 of the Apple Distribution cert.   |
| `APPLE_DIST_CERT_PASSWORD`     | build-ios          | Cert password.                          |
| `APPLE_PROVISION_PROFILE_BASE64`| build-ios        | Base64 of the ad-hoc/distribution profile.|
| `APPLE_API_KEY_BASE64`         | build-ios          | Base64 of the App Store Connect API key. |
| `APPLE_API_ISSUER`             | build-ios          | App Store Connect issuer id.             |
| `MATCH_PASSWORD` / `APPLE_KEY` | build-ios          | (alternative) Fastlane Match credentials.|

### Preparing the Android keystore

```bash
keytool -genkey -v -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias junglechat
base64 -w0 upload-keystore.jks > keystore_base64.txt
```

Paste the contents of `keystore_base64.txt` into the `KEYSTORE_BASE64` secret.

### Preparing iOS signing

Export your Distribution certificate and provisioning profile from Xcode →
*Settings → Accounts → Manage Certificates*, base64 them, and add as secrets.
The workflow decodes them into the macOS runner before `flutter build ipa`.

### Triggering a build

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions builds the APK/AAB and IPA and attaches them to the release.
(For local testing: `cd app && flutter build apk --release` and
`flutter build ipa --release`.)

---

## 3. Admin panel

See `docs/ADMIN.md` — it's a static web build (`flutter build web`) deployed to
any static host. No CI is required, but you can add a workflow that runs
`flutter build web` and publishes `build/web` to Cloudflare Pages / Firebase.

---

## 4. End-to-end smoke test (do this before any store submission)

1. `supabase db push` + deploy the two functions.
2. Install the app (or run `flutter run`); create an account; confirm an animal
   id is assigned.
3. Open the admin panel; grant an admin; sign in with MFA.
4. Send a message between two test accounts; confirm auto-delete, reactions, and
   app-lock behave.
5. As admin, open a report and remove a public message; confirm it disappears in
   the app.
