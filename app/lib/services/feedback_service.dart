import 'dart:async';

import 'package:flutter/services.dart';

/// Central haptic feedback ("anonymous" interface: muted, no sounds).
/// Honors the user's server-side haptic preference pushed here by HomeShell
/// whenever the profile loads or changes.
class FeedbackService {
  FeedbackService._();

  static bool hapticsEnabled = true;

  // ---- Haptics ------------------------------------------------------------

  static void hapticTap() {
    if (!hapticsEnabled) return;
    HapticFeedback.selectionClick();
  }

  static void hapticSend() {
    if (!hapticsEnabled) return;
    HapticFeedback.lightImpact();
  }

  static void hapticAlert() {
    if (!hapticsEnabled) return;
    HapticFeedback.mediumImpact();
  }

  static void hapticError() {
    if (!hapticsEnabled) return;
    HapticFeedback.heavyImpact();
  }

  // ---- Combined convenience ----------------------------------------------

  /// The app-wide click: haptic only. Returns null for a null action, so
  /// disabled buttons stay disabled.
  static void tap() {
    hapticTap();
  }

  /// Wraps a tap handler so the click fires before the action:
  /// `onPressed: FeedbackService.click(() => context.push('/meet'))`.
  /// Returns null for a null action, so disabled buttons stay disabled.
  static void Function()? click(FutureOr<void> Function()? action) {
    if (action == null) return null;
    return () {
      tap();
      action();
    };
  }

  static void tabSwitch() {
    hapticTap();
  }

  static void messageSent() {
    hapticSend();
  }

  static void alert() {
    hapticAlert();
  }

  static void failure() {
    hapticError();
  }
}
