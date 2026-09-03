import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/ad_config.dart';

/// Initializes the AdMob SDK exactly once for the lifetime of the process.
/// [MobileAds.instance.initialize] is cheap to call repeatedly, but we still
/// guard it so the test/real SDK is only booted a single time.
bool _adsInitialized = false;
Future<void> _ensureAdsInitialized() async {
  if (_adsInitialized) return;
  await MobileAds.instance.initialize();
  _adsInitialized = true;
}

/// Ad-gated animal-change session. Talks to the Supabase RPCs that enforce the
/// 2-changes-per-day quota and perform the actual swap. Do NOT change these.
class AdChangeSession {
  static Future<({int used, int remaining})> quota() async {
    final rows = await Supabase.instance.client.rpc('ad_change_quota');
    if (rows is List && rows.isNotEmpty) {
      final j = Map<String, dynamic>.from(rows.first);
      return (
        used: (j['used_today'] as num?)?.toInt() ?? 0,
        remaining: (j['remaining_today'] as num?)?.toInt() ?? 0,
      );
    }
    return (used: 0, remaining: 2);
  }

  static Future<String> begin() async {
    return await Supabase.instance.client.rpc('begin_ad_change') as String;
  }

  static Future<String> complete(String sessionToken, String newAnimal) async {
    return await Supabase.instance.client.rpc(
      'complete_ad_change',
      params: {'p_session': sessionToken, 'p_new_animal': newAnimal},
    ) as String;
  }
}

/// Shows a rewarded ad and resolves `true` ONLY when the user earns the reward
/// (watches it to completion). Any other outcome — load failure, dismiss,
/// skip, or error — resolves `false`, so the caller must treat `false` as
/// "no change happened".
///
/// Uses AdMob TEST ads. The [context] is part of the public API contract and
/// kept for callers that previously pushed a full-screen route.
Future<bool> showRewardedAd(BuildContext context) async {
  await _ensureAdsInitialized();

  final completer = Completer<bool>();
  var earned = false;

  unawaited(
    RewardedAd.load(
      adUnitId: AdConfig.rewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          ad.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (d) {
              d.dispose();
              if (!completer.isCompleted) completer.complete(earned);
            },
            onAdFailedToShowFullScreenContent: (d, _) {
              d.dispose();
              if (!completer.isCompleted) completer.complete(false);
            },
            onAdImpression: (_) {},
          );
          ad.show(onUserEarnedReward: (_, _) => earned = true);
        },
        onAdFailedToLoad: (error) {
          if (!completer.isCompleted) completer.complete(false);
        },
      ),
    ),
  );

  return completer.future;
}
