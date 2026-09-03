import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../../services/ad_service.dart';
import '../../services/security_service.dart';
import '../../services/auth_service.dart';
import '../../services/feedback_service.dart';
import '../../core/animal_glyph.dart';
import '../../core/animal_picker.dart';
import '../auth/welcome_screen.dart';
import '../home/home_shell.dart';
import '../home/home_tab.dart';
import '../reports/report_sheet.dart';
import '../settings/auto_delete_timer_dialog.dart';
import '../update/update_flow.dart';
import '../lock/passcode_service.dart';
import '../lock/passcode_setup_screen.dart';

/// PRD Â§61 ” identity + privacy controls. Not a social profile.
class MineTab extends ConsumerStatefulWidget {
  const MineTab({super.key});

  @override
  ConsumerState<MineTab> createState() => _MineTabState();
}

class _MineTabState extends ConsumerState<MineTab> {
  List<AnimalCard>? _blocks;
  bool? _pinSet;
  // Resolved once — a FutureBuilder creating the future in build() re-hits
  // the platform channel on every rebuild (each settings toggle rebuilds
  // the whole tab).
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  @override
  void initState() {
    super.initState();
    _loadBlocks();
    _loadPinState();
  }

  Future<void> _loadPinState() async {
    final set = await PasscodeService.instance.isPinSet();
    if (!mounted) return;
    setState(() => _pinSet = set);
  }

  Future<void> _loadBlocks() async {
    try {
      final b = await ref.read(socialServiceProvider).myBlocks();
      if (!mounted) return;
      setState(() => _blocks = b);
    } catch (_) {
      if (!mounted) return;
      setState(() => _blocks = []);
    }
  }

  /// Ad-gated animal change: pick animal -> watch 1 rewarded ad -> change.
  /// 2 changes/day max, enforced server-side. Cancel anytime - a cancelled
  /// ad consumes nothing.
  Future<void> _changeAnimal(BuildContext context) async {
    // 0. Quota + rules first.
    ({int used, int remaining}) quota;
    try {
      quota = await AdChangeSession.quota();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
      return;
    }

    if (!context.mounted) return;
    final newAnimal = await showAnimalPickerSheet(
      context,
      title: 'CHANGE YOUR ANIMAL',
    );
    if (newAnimal == null || !context.mounted) return;
    await _confirmAndRunAdChange(context, newAnimal, quota.remaining);
  }

  Future<void> _confirmAndRunAdChange(
    BuildContext context,
    String newAnimal,
    int remaining,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: JCColors.surface,
        title: const Text('WATCH AN AD TO CHANGE'),
        content: Text(
          'Change to $newAnimal?\n\n'
          '- Watch 1 short ad to unlock this change\n'
          '- You have $remaining of 2 changes left today\n'
          '- Cancel the ad anytime - nothing is used',
          style: JCTypography.secondary.copyWith(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: FeedbackService.click(
              () => Navigator.pop(dlgCtx, false),
            ),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: FeedbackService.click(() => Navigator.pop(dlgCtx, true)),
            child: const Text('WATCH AD'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    // Begin server session (before the ad).
    String session;
    try {
      session = await AdChangeSession.begin();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().contains('AD_QUOTA_EXHAUSTED')
                ? 'No changes left today. Come back tomorrow.'
                : SafeErrors.message(e),
          ),
        ),
      );
      return;
    }

    // The ad. Cancel = no change, session expires unused.
    // Phase 4: FLAG_SECURE blanks the ad creative, so lift it for the duration
    // of the rewarded-ad screen and re-apply afterwards.
    await SecurityFlags.setSecure(false);
    if (!context.mounted) return;
    final granted = await showRewardedAd(context);
    await SecurityFlags.setSecure(true);
    if (!context.mounted) return;
    if (granted != true) {
      _toast(context, 'Ad cancelled - nothing was used.');
      return;
    }

    // Complete: consume session + perform the change.
    try {
      final newId = await AdChangeSession.complete(session, newAnimal);
      if (!context.mounted) return;
      ref.invalidate(myProfileProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('You are now $newId. The whole jungle can see it.'),
        ),
      );
      FeedbackService.messageSent();
    } catch (e) {
      if (!context.mounted) return;
      FeedbackService.failure();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    }
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Phase 6: set THIS account's default disappearing-message timer. New
  /// chats pick it up automatically; each chat can still override it.
  Future<void> _openDefaultAutoDelete(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final raw = await AuthService().getCurrentDefaultAutoDelete();
      if (!context.mounted) return;
      final initial = autoDeleteOptionFromInterval(raw);
      if (!context.mounted) return;
      await showAutoDeleteTimerDialog(
        context,
        defaultMode: true,
        title: 'Default Disappearing Messages',
        initialValue: initial,
      );
      if (!context.mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Default timer saved.')),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    }
  }

  /// Bio editor: optional, public, max 160 characters (enforced again
  /// server-side). Saving an empty bio clears it.
  void _openBioSheet(BuildContext context) {
    final profile = ref.read(myProfileProvider).value;
    final controller = TextEditingController(text: profile?.bio ?? '');
    bool busy = false;
    String? error;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: JCColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 22,
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 22,
          ),
          // The button row is PINNED below the scrollable area: only the
          // text field scrolls, so CANCEL / SAVE BIO stay visible no matter
          // how tall the keyboard is.
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('YOUR BIO', style: JCTypography.title),
              const SizedBox(height: 6),
              const Text(
                'Optional and public — every animal can see it. '
                'No personal details.',
                style: JCTypography.secondary,
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: controller,
                        maxLines: 3,
                        maxLength: 160,
                        decoration: const InputDecoration(
                          labelText: 'Bio (optional)',
                          counterText: '',
                          hintText: 'A few words about you…',
                        ),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          error!,
                          style: const TextStyle(color: JCColors.danger),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: busy
                        ? null
                        : FeedbackService.click(() => Navigator.pop(sheetCtx)),
                    child: const Text('CANCEL'),
                  ),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : FeedbackService.click(() async {
                            setSheet(() {
                              busy = true;
                              error = null;
                            });
                            try {
                              await AuthService().updateSettings(
                                bio: controller.text.trim(),
                              );
                              ref.invalidate(myProfileProvider);
                              if (!sheetCtx.mounted) return;
                              Navigator.pop(sheetCtx);
                            } catch (e) {
                              setSheet(() {
                                busy = false;
                                error = SafeErrors.message(e);
                              });
                            }
                          }),
                    child: Text(busy ? 'SAVING…' : 'SAVE BIO'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(controller.dispose);
  }

  /// Set or change the login password. Reauthentication required: the user
  /// proves identity with the CURRENT secret (recovery credential or the
  /// existing password). Server-side verified.
  void _openPasswordSheet(BuildContext context) {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    bool busy = false;
    String? error;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: JCColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 22,
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 22,
          ),
          // Scrollable so SAVE PASSWORD stays reachable with the keyboard open.
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('LOGIN PASSWORD', style: JCTypography.title),
                const SizedBox(height: 6),
                const Text(
                  'Prove it is you with your recovery credential '
                  '(or current password), then choose a new password.',
                  style: JCTypography.secondary,
                ),
                const SizedBox(height: 16),
                // Fields scroll; SAVE PASSWORD is pinned below and always
                // reachable, whatever the keyboard height.
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(
                          controller: current,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Current credential or password',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: next,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'New password (min 8 characters)',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: confirm,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Repeat new password',
                          ),
                        ),
                        if (error != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            error!,
                            style: const TextStyle(color: JCColors.danger),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                OverflowBar(
                  alignment: MainAxisAlignment.end,
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: busy
                          ? null
                          : FeedbackService.click(() async {
                              if (next.text.length < 8) {
                                setSheet(
                                  () => error = 'New password must be at least 8 characters.',
                                );
                                return;
                              }
                              if (next.text != confirm.text) {
                                setSheet(
                                  () =>
                                      error = 'The two passwords do not match.',
                                );
                                return;
                              }
                              setSheet(() {
                                busy = true;
                                error = null;
                              });
                              try {
                                await AuthService().setLoginPassword(
                                  currentSecret: current.text,
                                  newPassword: next.text,
                                );
                                if (!sheetCtx.mounted) return;
                                Navigator.pop(sheetCtx);
                                ScaffoldMessenger.of(sheetCtx).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Password saved. Use it on the login screen.',
                                    ),
                                  ),
                                );
                              } catch (e) {
                                setSheet(() {
                                  busy = false;
                                  error =
                                      e.toString().contains(
                                        'CURRENT_SECRET_WRONG',
                                      )
                                      ? 'The current credential or password is wrong.'
                                      : SafeErrors.message(e);
                                });
                              }
                            }),
                      child: Text(busy ? 'SAVING…' : 'SAVE PASSWORD'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(() {
      // Always release the three controllers — the sheet may be dismissed by
      // Navigator.pop, by tapping outside, by the back gesture, or by a route
      // replacement, all of which leave them orphaned otherwise.
      current.dispose();
      next.dispose();
      confirm.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(myProfileProvider);

    return profile.when(
      loading: () => const Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: JCColors.accent,
        ),
      ),
      error: (_, _) => const Center(child: Text('Could not load profile.')),
      data: (p) {
        if (p == null) {
          // Session exists but the profile is gone/corrupt (e.g. persisted by
          // an older broken build). Self-heal: sign out and start clean.
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Your session is no longer valid.\n'
                  'Sign in again to continue.',
                  textAlign: TextAlign.center,
                  style: JCTypography.secondary,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: FeedbackService.click(() async {
                    await Supabase.instance.client.auth.signOut();
                    if (!context.mounted) return;
                    context.go('/welcome');
                  }),
                  child: const Text('SIGN IN AGAIN'),
                ),
              ],
            ),
          );
        }
        final mine = !p.openToTalk;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 8),
            Center(
              child: Column(
                children: [
                  AnimalGlyph(animal: p.animal, size: 56),
                  const SizedBox(height: 10),
                  Text(
                    p.displayAnimalId,
                    style: JCTypography.animalId.copyWith(
                      fontSize: 22,
                      letterSpacing: 2,
                    ),
                  ),
                  Text(
                    mine ? 'Mine Mode' : 'Open to Talk',
                    style: TextStyle(
                      color: mine
                          ? JCColors.textSecondary
                          : JCColors.onlineGreen,
                    ),
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: FeedbackService.click(() async {
                      // Actually copy before telling the user it worked.
                      await Clipboard.setData(
                        ClipboardData(text: p.displayAnimalId),
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Your Animal ID has been copied. Share it with animals you trust.',
                          ),
                        ),
                      );
                    }),
                    icon: const Icon(Icons.share_outlined, size: 18),
                    label: const Text('Share My Animal ID'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: FeedbackService.click(
                      () => context.push('/my-qr'),
                    ),
                    icon: const Icon(Icons.qr_code_2, size: 18),
                    label: const Text('My QR Code'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: FeedbackService.click(
                      () => _changeAnimal(context),
                    ),
                    icon: const Icon(Icons.swap_horiz, size: 18),
                    label: const Text('Change Animal'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 26),
            Card(
              child: SwitchListTile(
                activeThumbColor: JCColors.accent,
                title: Text(
                  mine ? 'MINE MODE' : 'OPEN TO TALK',
                  style: JCTypography.body.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  mine
                      ? 'You are hidden from discovery.'
                      : 'You can be discovered by other animals.',
                  style: JCTypography.secondary,
                ),
                value: p.openToTalk,
                onChanged: (v) async {
                  FeedbackService.tap();
                  try {
                    await ref
                        .read(authServiceProvider)
                        .updateSettings(openToTalk: v, randomTalk: v);
                    ref.invalidate(myProfileProvider);
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(SafeErrors.message(e))),
                    );
                  }
                },
              ),
            ),
            if (p.openToTalk)
              Card(
                child: SwitchListTile(
                  activeThumbColor: JCColors.accent,
                  title: Text('RANDOM TALK', style: JCTypography.body),
                  subtitle: Text(
                    'Appear in Random Talk matching.',
                    style: JCTypography.secondary,
                  ),
                  value: p.randomTalkEnabled,
                  onChanged: (v) async {
                    FeedbackService.tap();
                    try {
                      await ref
                          .read(authServiceProvider)
                          .updateSettings(randomTalk: v);
                      ref.invalidate(myProfileProvider);
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(SafeErrors.message(e))),
                      );
                    }
                  },
                ),
              ),
            if (p.openToTalk)
              Card(
                child: SwitchListTile(
                  activeThumbColor: JCColors.accent,
                  title: Text('TYPING INDICATOR', style: JCTypography.body),
                  subtitle: Text(
                    'Show when the other animal is typing.',
                    style: JCTypography.secondary,
                  ),
                  value: p.typingIndicatorEnabled,
                  onChanged: (v) async {
                    FeedbackService.tap();
                    try {
                      await ref
                          .read(authServiceProvider)
                          .updateSettings(typingIndicator: v);
                      ref.invalidate(myProfileProvider);
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(SafeErrors.message(e))),
                      );
                    }
                  },
                ),
              ),
            Card(
              child: SwitchListTile(
                activeThumbColor: JCColors.accent,
                title: Text('HAPTICS', style: JCTypography.body),
                subtitle: Text(
                  'Subtle vibration feedback on touches.',
                  style: JCTypography.secondary,
                ),
                value: p.hapticsEnabled,
                onChanged: (v) async {
                  FeedbackService.tap();
                  try {
                    await ref
                        .read(authServiceProvider)
                        .updateSettings(haptics: v);
                    ref.invalidate(myProfileProvider);
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(SafeErrors.message(e))),
                    );
                  }
                },
              ),
            ),
            Card(
              child: SwitchListTile(
                activeThumbColor: JCColors.accent,
                title: Text('SHOW ONLINE STATUS', style: JCTypography.body),
                subtitle: Text(
                  'Show a green dot to other animals while you are using '
                  'the app. Turning it off hides your online status.',
                  style: JCTypography.secondary,
                ),
                value: p.visibilityOnline,
                onChanged: (v) async {
                  FeedbackService.tap();
                  try {
                    await ref
                        .read(authServiceProvider)
                        .updateSettings(visibilityOnline: v);
                    ref.invalidate(myProfileProvider);
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(SafeErrors.message(e))),
                    );
                  }
                },
              ),
            ),
            Card(
              child: ListTile(
                title: Text('BIO', style: JCTypography.body),
                subtitle: Text(
                  p.bio == null || p.bio!.isEmpty
                      ? 'Add an optional public bio (max 160 characters).'
                      : p.bio!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: JCTypography.secondary,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: FeedbackService.click(() => _openBioSheet(context)),
              ),
            ),
            const SizedBox(height: 18),

            // ---- App updates ----------------------------------------------
            Text(
              'APP',
              style: JCTypography.secondary.copyWith(
                fontSize: 12,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 6),
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.system_update_outlined,
                  color: JCColors.textSecondary,
                ),
                title: const Text(
                  'Check for updates',
                  style: JCTypography.body,
                ),
                subtitle: FutureBuilder<PackageInfo>(
                  future: _packageInfo,
                  builder: (context, snap) {
                    final info = snap.data;
                    return Text(
                      info == null
                          ? 'See if a newer version is available.'
                          : 'Current version ${info.version} '
                                '(${info.buildNumber})',
                      style: JCTypography.secondary,
                    );
                  },
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: FeedbackService.click(
                  () => UpdateFlow.checkAndPresent(feedback: true),
                ),
              ),
            ),

            const SizedBox(height: 18),

            // ---- Security: login password --------------------------------
            Text(
              'SECURITY',
              style: JCTypography.secondary.copyWith(
                fontSize: 12,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 6),
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.password_outlined,
                  color: JCColors.textSecondary,
                ),
                title: const Text('Login password', style: JCTypography.body),
                subtitle: const Text(
                  'Set a password so you can log in without typing the '
                  'recovery credential. The credential stays your master key.',
                  style: JCTypography.secondary,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: FeedbackService.click(() => _openPasswordSheet(context)),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.lock_outline,
                  color: JCColors.textSecondary,
                ),
                title: const Text('App lock', style: JCTypography.body),
                subtitle: Text(
                  _pinSet == true
                      ? 'A 6-digit passcode locks the app. Tap to change it.'
                      : 'Require a 6-digit passcode on open and after backgrounding.',
                  style: JCTypography.secondary,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: FeedbackService.click(() async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PasscodeSetupScreen(
                        onDone: () {
                          Navigator.of(context).pop();
                          _loadPinState();
                        },
                      ),
                    ),
                  );
                }),
              ),
            ),

            const SizedBox(height: 18),

            // ---- Disappearing messages -----------------------------------
            Text(
              'DISAPPEARING MESSAGES',
              style: JCTypography.secondary.copyWith(
                fontSize: 12,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 6),
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.timer_outlined,
                  color: JCColors.textSecondary,
                ),
                title: const Text(
                  'Default timer',
                  style: JCTypography.body,
                ),
                subtitle: const Text(
                  'New chats disappear after this time unless changed. '
                  'Each chat can override it.',
                  style: JCTypography.secondary,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: FeedbackService.click(
                  () => _openDefaultAutoDelete(context),
                ),
              ),
            ),

            // ---- Report & Help -------------------------------------------
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.support_agent_outlined,
                  color: JCColors.textSecondary,
                ),
                title: const Text('Report & Help', style: JCTypography.body),
                subtitle: const Text(
                  'Send an anonymous report or message to the admin.',
                  style: JCTypography.secondary,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: FeedbackService.click(
                  () => showReportSheet(context, ref, type: 'other'),
                ),
              ),
            ),

            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'BLOCKED ANIMALS',
                  style: JCTypography.secondary.copyWith(
                    fontSize: 12,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
            ...(_blocks ?? []).map(
              (b) => ListTile(
                leading: AnimalGlyph(animal: b.animal, size: 24),
                title: Text(b.displayAnimalId, style: JCTypography.animalId),
                trailing: TextButton(
                  onPressed: FeedbackService.click(() async {
                    try {
                      await ref.read(socialServiceProvider).unblock(b.id);
                      await _loadBlocks();
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(SafeErrors.message(e))),
                      );
                    }
                  }),
                  child: const Text('Unblock'),
                ),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(foregroundColor: JCColors.danger),
              onPressed: FeedbackService.click(() async {
                await Supabase.instance.client.auth.signOut();
                if (!context.mounted) return;
                context.go('/welcome');
              }),
              child: const Text('LOGOUT'),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                '${p.daysUntilDelete} days until inactivity deletion.\n'
                'Any activity resets the timer automatically.',
                textAlign: TextAlign.center,
                style: JCTypography.secondary.copyWith(fontSize: 12),
              ),
            ),
          ],
        );
      },
    );
  }
}
