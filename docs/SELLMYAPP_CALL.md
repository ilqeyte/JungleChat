# JungleChat — SellMyApp Screen-Call Script (15–30 min)

A teleprompter for the live screen-share call with a prospective buyer.
Read it naturally, drive the app on screen, and you will come across as the
person who built JungleChat — because you can show every part of it working.

**Before the call (5 min setup):**
- Open the **mobile app** on a real device (or emulator) and the **admin panel**
  in a browser tab, both already signed in.
- Have two test accounts ready so you can show a live 1:1 chat.
- Keep `docs/WHITE_LABEL.md` and `docs/DEPLOY.md` open in a second tab to point
  at when you talk about rebranding and CI.
- Mute notifications you don't want on screen. Close anything personal.

**Golden rule:** show, don't tell. Every claim below has a screen action.

---

## 1. Cold open — who you are (0:00–2:00)

> "Hey, thanks for hopping on. I'm [name], I built JungleChat — it's an
> anonymous, animal-themed chat app. No phone number, no email, no profile to
> stalk. You get an animal identity and you talk. I'll give you a quick tour
> live, then we can dig into whatever matters for you."

**On screen:** JungleChat icon + onboarding screen, full-screen.
**Talking point:** You wrote it in Flutter, so one codebase ships to Android
and iOS, and there's a matching Flutter **web admin panel** you run from a
browser. That's the whole product: a client, an admin, and a Supabase backend.

---

## 2. The problem and the wedge (2:00–4:30)

> "Everyone's tired of handing over a phone number just to message someone.
> JungleChat flips that — you open it, you're an animal, you chat. Messages
> self-delete, you can go invisible, and there's no social-graph to mine. It's
> the privacy-first chat app, but it still feels playful, not paranoid."

**On screen:** tap through onboarding to show how fast it is — no form, just
"Continue".
**Talking point:** the wedge is *anonymous but trustworthy*: reactions and
moderation exist, so it's not a spam pit. That balance is the hard part, and
it's already solved in the codebase.

---

## 3. Architecture in 60 seconds (4:30–6:00)

> "Three pieces. The mobile app — Flutter, one codebase for both stores. A web
> admin panel — also Flutter, so the same language end to end, no JS/Python
> context-switch. And Supabase on the backend: Postgres, auth, realtime, and
> Edge Functions. Row Level Security is the backbone — clients never touch the
> database directly, they call server-side functions I wrote."

**On screen:** briefly show the repo file tree (`app/`, `admin/`, `supabase/`)
or the three folders side by side.
**Talking point:** this is a *complete* product, not a UI shell. Backend,
admin, mobile, and CI are all included.

---

## 4. Live mobile demo (6:00–16:00)

### 4.1 Anonymous onboarding + animal identity (6:00–8:00)
**Action:** show a fresh account being created (or already created). Point at
the animal id (e.g. "Mossy Fox #4821") and the **recovery credential**.
> "You don't enter an email. The app mints an animal identity. The one thing I
> do give you is a recovery credential — a short phrase — so if you reinstall,
> you get your identity back. No password to forget, no PII to leak."

### 4.2 Real-time animal-to-animal chat + reactions (8:00–10:00)
**Action:** open a chat with your second test account; send a message; on the
other device show it arrive live; tap a **reaction**.
> "Realtime over Supabase websockets. Reactions are built in — light, fun, low
> friction. Everything is server-authoritative so it stays consistent."

### 4.3 Message auto-delete / ephemeral (10:00–11:30)
**Action:** show a message vanish after its TTL, or open the auto-delete
setting.
> "Messages expire and delete themselves. That's the core privacy promise, and
> it's enforced server-side, not just hidden in the UI — deleted rows are gone,
> not soft-marked."

### 4.4 Mine Mode — go invisible (11:30–13:00)
**Action:** toggle **Mine Mode** (was "Shadow Mode" in earlier builds — I
renamed it to match the brand). Show discoverability drop.
> "Mine Mode makes you undiscoverable — you keep your existing chats but you
> don't show up to new animals. Think 'invisible but still connected'."

### 4.5 Change animal via rewarded ad, twice a day (13:00–14:30)
**Action:** trigger the "change animal" flow; show the rewarded-ad gate.
> "You can re-roll your animal, gated behind a rewarded ad — twice a day. That's
> the monetization hook: AdMob rewarded ads, test ids shipped so it runs out of
> the box, your ids dropped in for release. Simple, policy-clean."

### 4.6 App lock (14:30–15:15)
**Action:** background the app, reopen, show the lock.
> "Local app lock — biometric or PIN — so a roommate grabbing your phone can't
> read your chats. Cheap to build, expected by users, done."

### 4.7 Push + in-app updates (15:15–16:00)
**Action:** send a push from the admin or show the notification; mention
in-app update.
> "Firebase push for new messages, and an in-app update path so you can ship a
> new APK to users without a store round-trip. Both wired and tested."

---

## 5. Admin panel demo (16:00–24:00)

### 5.1 MFA-gated sign-in (16:00–17:30)
**Action:** open the admin URL, sign in, show the TOTP step.
> "The admin is locked behind MFA — not just a password, a TOTP factor. A
> stolen password gets you nothing. Two gates: the database checks you're an
> admin *and* MFA-elevated, and the app won't show a single admin screen
> otherwise."

### 5.2 Dashboard (17:30–19:00)
**Action:** land on Dashboard; show user / open-report / support counts.
> "At a glance: active users, open reports, support volume, recent admin
> activity. Everything an operator needs to see at 9am."

### 5.3 User management (19:00–21:00)
**Action:** open Users; set a status (mute / suspend / ban); show the
hard-delete action.
> "Per-user controls: active, mute, suspend, ban. And a real hard-delete that
> goes through a dedicated Edge Function with the caller verified server-side —
> no client can just wipe rows. That's the safe way to do moderation."

### 5.4 Reports & moderation (21:00–22:30)
**Action:** open Reports; resolve one; show removing the reported *public*
message.
> "Reports come in, you resolve them, and for a public-message report you can
> pull the message. Crucially, private DMs are structurally unreachable by the
> moderation queries — admins can't read private conversations. That's a
> design guarantee, not a promise."

### 5.5 White-label at runtime (22:30–24:00)
**Action:** open White-label; change the display name / tagline / brand color
live; show it reflect in the app on next launch.
> "Most of the rebrand is live — no rebuild. App name, tagline, colors, support
> links, feature toggles: edit here, the app reads it on launch. Deep stuff —
> icon, package id — needs a rebuild, and that's documented."

---

## 6. Backend & security (24:00–27:00)

> "Quick word on the part buyers can't see. Every privileged operation is a
> Postgres function with `security definer`, behind Row Level Security. Clients
> call functions; they never own the schema. The admin surface is MFA-gated at
> both the database and the app. Migrations are versioned and ordered, so
> `supabase db push` is a one-command, repeatable deploy. Edge Functions handle
> account creation, login, uploads, and push — all server-side."

**On screen:** optionally open `supabase/migrations/` to show it's a clean,
ordered set; open `supabase/functions/` to show the functions.
**Talking point:** "This is production-shaped. It's not a prototype with
`TODO`s in the auth path."

---

## 7. White-label depth & handover (27:00–30:00)

**Action:** point at `docs/WHITE_LABEL.md` and `docs/DEPLOY.md`.
> "Rebranding is documented end to end. Build-time: package id
> (`com.junglechat.app`), app name, theme colors, Supabase keys, AdMob ids,
> icon — all in one checklist. Runtime: the admin panel. CI is GitHub Actions:
> tag `v1.0.0`, you get a signed APK/AAB and an IPA built for you, plus the web
> admin as a static site. Handover is: clone, push migrations, set a few
> secrets, done."

**Talking point:** "What you're buying is the whole thing — mobile, admin,
backend, docs, and a working demo backend I can hand over or you can point at
your own Supabase in an afternoon."

---

## 8. Pricing & close (30:00–32:00)

> "I'm asking [price] for the full source, the admin panel, the backend, and
> the docs — everything needed to publish under your own brand. Comparable
> anonymous-chat templates go for more and ship less. I'll throw in a week of
> async support to get your first build green. Happy to do a second, deeper
> technical call with your dev if that helps."

**CTA:** "If it's a fit, I can transfer the repo and the demo backend today.
What questions can I answer?"

---

## Objection handling (keep in your back pocket)

- **"Is it really anonymous?"** — No email/phone at signup; identity is an
  animal + recovery phrase. Private DMs are server-unreachable by moderation.
- **"Can I rebrand it?"** — Yes, build-time + runtime, full checklist in
  `WHITE_LABEL.md`. Most branding is live from the admin panel.
- **"Will it pass store review?"** — Standard Flutter app, AdMob test ids
  shipped, no policy-red-flag features. You swap in your AdMob/Firebase/Supabase.
- **"Is the backend solid?"** — RLS + `security definer` RPCs, MFA-gated admin,
  versioned migrations, server-side Edge Functions. Not a prototype.
- **"What about iOS?"** — Same Flutter codebase; `build-ios.yml` produces a
  signed IPA on GitHub macOS runners. You supply the cert/profile.
- **"Can I see the code?"** — The repo is public; every screen I showed maps to
  a file. Point them at `app/`, `admin/`, `supabase/`.

---

## Demo-day checklist (so nothing breaks on call)

- [ ] Mobile app signed in, two test accounts, one animal each.
- [ ] Admin panel signed in with MFA (TOTP app ready).
- [ ] Rewarded-ad flow shows the ad (test AdMob ids).
- [ ] Push demo works (Firebase project configured).
- [ ] White-label edit reflects on app relaunch.
- [ ] `docs/WHITE_LABEL.md` and `docs/DEPLOY.md` open for reference.
- [ ] Screen-share set to the app window only; personal tabs closed.
