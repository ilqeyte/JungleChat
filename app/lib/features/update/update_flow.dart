import 'package:flutter/material.dart';

import '../../core/router.dart';
import '../../models/app_update.dart';
import 'update_downloader.dart';
import 'update_gate.dart';

/// Single entry point for *showing* update UI outside of [UpdateGate].
///
/// The gate owns the blocking screen (a required release whose grace period
/// has passed replaces the whole app). Everything user-initiated — tapping
/// the "new version" push notification, the "Check for updates" tile in
/// settings — goes through [checkAndPresent], which re-checks the server and
/// routes to the right surface:
///
///   * required & due  → [UpdateGate.reload] (gate swaps in the blocking
///                       screen on its next check)
///   * optional        → the /update page (dismissible, same download UI)
///   * nothing newer   → a small confirmation when the user asked manually
///
/// All of this stays inside the app: the APK is downloaded with a progress
/// bar straight from the published URL (R2 upload or admin link — same
/// thing from the client's point of view) and handed to the Android package
/// installer as an overlay.
class UpdateFlow {
  UpdateFlow._();

  static final UpdateDownloader _downloader = UpdateDownloader();

  /// Release ids already auto-prompted this session. The gate prompts an
  /// optional release once; a *user-initiated* check bypasses this via
  /// [presentOptional]'s force flag.
  static final Set<String> _promptedIds = {};

  /// True while the /update page is open or opening. Prevents stacking two
  /// update pages when (for example) the gate's startup prompt and a
  /// notification tap land in the same frame.
  static bool _routeOpenOrPending = false;

  /// Called by [UpdateScreenPage] when the route goes away.
  static void updateRouteClosed() => _routeOpenOrPending = false;

  /// Runs a fresh check and presents the result.
  ///
  /// Set [feedback] for user-initiated checks (settings tile, notification
  /// taps) so a "nothing newer" or "check failed" state is acknowledged
  /// instead of silently doing nothing.
  static Future<void> checkAndPresent({bool feedback = false}) async {
    // Wait for the gate's first check so the app's router is mounted — a
    // cold start triggered by a notification tap can beat it.
    try {
      await UpdateGate.ready.timeout(const Duration(seconds: 10));
    } catch (_) {
      // Gate never finished (offline?): still try; the push below is
      // post-frame guarded and simply no-ops if the router is not there.
    }

    AppUpdate? update;
    try {
      update = await _downloader.checkForUpdate();
    } catch (_) {
      if (feedback) _toast('Could not check for updates right now.');
      return;
    }

    if (update == null) {
      if (feedback) _toast('You are already on the latest version.');
      return;
    }

    if (_downloader.isRequiredNow(update)) {
      // The gate owns the blocking screen; ask it to re-check and take over.
      UpdateGate.reload();
      return;
    }

    presentOptional(update, force: true);
  }

  /// Shows the /update page for a non-blocking release.
  ///
  /// Auto-prompts (gate) fire once per release per session. [force]
  /// (notification tap, settings) always shows — unless a page is already
  /// open, in which case there is nothing to add.
  static void presentOptional(AppUpdate update, {bool force = false}) {
    if (_routeOpenOrPending) return;
    if (!force && _promptedIds.contains(update.id)) return;
    _promptedIds.add(update.id);
    _routeOpenOrPending = true;

    // Post-frame: the gate may have just called setState to swap in the
    // real app for the first time — the router must be mounted before push.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        appRouter.push('/update', extra: update);
      } catch (_) {
        // Router not available (e.g. gate is blocking): release the guard so
        // a later attempt can still show the page.
        _routeOpenOrPending = false;
      }
    });
  }

  static void _toast(String message) {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(message)));
  }
}
