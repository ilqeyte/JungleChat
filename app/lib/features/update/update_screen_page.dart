import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/app_update.dart';
import '../../services/feedback_service.dart';
import 'required_update_screen.dart';
import 'update_downloader.dart';
import 'update_flow.dart';

/// Route page for /update.
///
/// Reached from a notification tap, the "Check for updates" tile in
/// settings, or the gate's optional-release prompt. Carries the full
/// in-app flow: What's New, streamed download with progress, the Android
/// installer permission deep-link, and the package installer itself — no
/// browser, never leaving the app.
///
/// The gate only pushes this page for releases that exist and are newer
/// than the running build, but the page still defends itself: it refetches
/// when opened without an update (cold deep-link restore) and shows a
/// graceful "up to date" state.
class UpdateScreenPage extends StatefulWidget {
  final AppUpdate? update;

  const UpdateScreenPage({super.key, this.update});

  @override
  State<UpdateScreenPage> createState() => _UpdateScreenPageState();
}

class _UpdateScreenPageState extends State<UpdateScreenPage> {
  final UpdateDownloader _downloader = UpdateDownloader();

  AppUpdate? _update;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // Lets the flow prompt again later in the session.
    UpdateFlow.updateRouteClosed();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      var update = widget.update;
      // Never trust a carried-in release: a stale notification extra (the
      // same tray notification tapped again after installing) must never
      // offer a download the user already has. If the carried update is not
      // strictly newer than the installed build, re-check the live release.
      if (update != null) {
        final currentCode = await _downloader.getCurrentVersionCode();
        if (update.versionCode <= currentCode) update = null;
      }
      update ??= await _downloader.checkForUpdate();
      if (!mounted) return;
      setState(() {
        _update = update;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: JCColors.background,
        body: Center(
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: JCColors.accent,
          ),
        ),
      );
    }

    final update = _update;
    if (update == null) {
      // Nothing newer (e.g. the release was pulled, or this is a stale
      // deep link after updating). Nothing to do but go back.
      return Scaffold(
        backgroundColor: JCColors.background,
        appBar: AppBar(title: const Text('Update')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.verified_outlined,
                size: 56,
                color: JCColors.accent,
              ),
              const SizedBox(height: 16),
              Text('You are on the latest version.', style: JCTypography.body),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: FeedbackService.click(
                  () => Navigator.of(context).maybePop(),
                ),
                child: Text('BACK', style: JCTypography.secondary),
              ),
            ],
          ),
        ),
      );
    }

    return RequiredUpdateScreen(
      update: update,
      // A required release whose grace period already passed is normally
      // handled by the gate's blocking screen; if the user lands here
      // anyway, still allow postponing until the gate takes over.
      dismissable: !_downloader.isRequiredNow(update),
    );
  }
}
