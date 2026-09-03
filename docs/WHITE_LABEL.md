# White-labeling JungleChat

JungleChat is built to be reskinned and re-published under your own brand
without touching the chat logic. This guide lists everything you can change and
exactly where.

Two kinds of branding:

- **Build-time branding** — baked into the app binary. Requires a rebuild
  (and, for store publishing, new signing keys). This is the app name, package
  id, icons, splash, and deep theme colors.
- **Runtime branding** — editable live from the admin panel via the
  `app_config` table. This is the display name, tagline, support contacts, and
  feature toggles the app reads on launch.

---

## 1. App identity (build-time)

### Android — `app/android/app/build.gradle`

```gradle
namespace = "com.junglechat.app"        // line ~15
applicationId = "com.junglechat.app"    // line ~26
```

Replace `com.junglechat.app` with your reverse-domain id (e.g.
`com.yourco.chatapp`). Also set the visible name in
`app/android/app/src/main/AndroidManifest.xml`:

```xml
android:label="JungleChat"   <!-- change to your app name -->
```

### iOS — `app/ios/Runner.xcodeproj/project.pbxproj`

```
PRODUCT_BUNDLE_IDENTIFIER = com.junglechat.app;
```

There are several occurrences (debug / release / profile). Change them all to
your bundle id. The display name lives in `app/ios/Runner/Info.plist`:

```xml
<key>CFBundleName</key>
<string>JungleChat</string>
<key>CFBundleDisplayName</key>
<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
```

(Set `CFBundleDisplayName` to your app name if you don't want the bundle id
shown.)

### Icon & splash

- Icon: drop your artwork into `app/android/app/src/main/res/mipmap-*` and
  `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/`, or run
  `flutter pub run flutter_launcher_icons` after updating
  `app/flutter_launcher_icons.yaml`.
- JungleChat intentionally ships **no logo** on the chat screens (privacy-first
  look). If you want a brand mark, add it where your design calls for it.

---

## 2. Theme colors (build-time)

`app/lib/core/theme.dart` defines `JCColors` (pure-black chrome, moss-green
accent) and `buildJungleTheme()`. Change the hex values there to retheme the
app. The web admin shares the same palette in `admin/lib/core/theme.dart`.

> Keep the nav container near-black for the intended look, but any palette is
> allowed.

---

## 3. Supabase backend (build-time)

`app/lib/core/config.dart` and `admin/lib/core/config.dart` both point at the
project. To use your own Supabase instance, create a project, push the
migrations (`supabase db push`), deploy the Edge Functions (see `docs/DEPLOY.md`),
then update:

```dart
const String supabaseUrl = 'https://<your-project>.supabase.co';
const String supabaseAnonKey = '<your publishable key>';
```

in **both** `app/lib/core/config.dart` and `admin/lib/core/config.dart` so the
app and the panel share one backend.

---

## 4. AdMob (build-time)

`app/lib/core/ad_config.dart` holds the AdMob app id and the rewarded-ad unit
id. The repo ships with **test** ids so nothing is charged and no policy
violation occurs until you fill in your own:

```dart
// ad_config.dart
const String adMobAppId  = 'ca-app-pub-3940256099942544~3347511713'; // test
const String rewardedAdUnitId = 'ca-app-pub-3940256099942544/5224354917'; // test
```

Replace both with the ids from your AdMob account before release. The rewarded
ad gates the "change animal id twice a day" feature.

---

## 5. Runtime branding (admin panel → `app_config`)

The `app_config` table is read by the app on launch (with safe local fallbacks),
so these take effect without a rebuild:

| Key         | Meaning                                                        |
|-------------|----------------------------------------------------------------|
| `app_name`  | Display name shown on onboarding.                            |
| `tagline`   | One-line marketing sentence.                                  |
| `brand`     | `{primary_color, accent_color, background_color}` as hex.     |
| `support`   | `{email, terms_url, privacy_url}`.                            |
| `features`  | `{reactions, auto_delete, app_lock, groups}` booleans.        |

Edit them in the admin panel → **White-label** section (see `docs/ADMIN.md`).
Deep branding (icon, splash, package id) still requires a rebuild as noted
above.

---

## Rebrand checklist

- [ ] Android `applicationId` + `namespace` + `android:label`
- [ ] iOS `PRODUCT_BUNDLE_IDENTIFIER` + `CFBundleName`/`CFBundleDisplayName`
- [ ] `JCColors` palette in `app/lib/core/theme.dart` (and `admin/lib/...`)
- [ ] `supabaseUrl` / `supabaseAnonKey` in `app/` and `admin/` `config.dart`
- [ ] AdMob ids in `app/lib/core/ad_config.dart`
- [ ] App icon + splash artwork
- [ ] Runtime `app_config` values via the admin panel
- [ ] `flutter pub get` + `flutter analyze` + a clean `flutter build apk`/`ipa`
