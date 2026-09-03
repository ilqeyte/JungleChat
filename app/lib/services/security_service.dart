import 'package:flutter/services.dart';

/// Phase 4 — screenshot / screen-recorder blocking bridge.
///
/// Talks to the native [SecurityFlagsPlugin] over `com.junglechat/security`.
/// The app is secure by default (FLAG_SECURE is (re)applied on resume natively);
/// [setSecure] lifts/re-applies the flag for surfaces that must be capturable —
/// currently only the rewarded-ad screen, whose creative renders black under
/// FLAG_SECURE. The ad screen shows no user content, so the privacy cost is nil.
class SecurityFlags {
  static const _channel = MethodChannel('com.junglechat/security');

  /// [secure] = true adds FLAG_SECURE (blocks screenshots/recording);
  /// [secure] = false clears it (used only for the ad screen).
  static Future<void> setSecure(bool secure) async {
    try {
      await _channel.invokeMethod<void>('setSecure', {'secure': secure});
    } on PlatformException {
      // Best-effort: a failure here must never crash the UI.
    }
  }
}
