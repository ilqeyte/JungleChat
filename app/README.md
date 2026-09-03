# JungleChat

Anonymous, animal-themed chat for people who'd rather not share a name. Meet
other animals, talk, react, and move on — messages self-delete, and your animal
identity is yours to reinvent (twice a day, backed by a rewarded ad).

This is the **mobile app** package. The companion Flutter web admin panel lives
in `../admin`, and the Supabase backend (migrations + edge functions) lives in
`../supabase`.

## Highlights

- Fully anonymous onboarding — no email, no phone. A recovery credential is
  generated locally so you can restore your animal on a new device.
- Auto-deleting messages, emoji reactions, and a "Mine Mode" (formerly Shadow)
  to go invisible.
- Change your animal id up to twice a day via a rewarded ad.
- App lock for an extra layer of privacy.
- Push notifications (Firebase) and in-app forced/silent updates.

## Getting started

```bash
flutter pub get
flutter run            # needs a device/emulator
```

You must point the app at your own Supabase project (see `../docs` and
`../supabase`). Copy `app/android/app/google-services.json` from your Firebase
project before building release APKs.

## Project layout

```
app/                 # this Flutter app
admin/               # Flutter web admin panel (MFA-gated)
supabase/            # migrations + edge functions
docs/                # README, ADMIN, WHITE_LABEL, DEPLOY
scripts/             # one-time bootstrap helpers
```

White-label buyers: read `../docs/WHITE_LABEL.md` before publishing.
