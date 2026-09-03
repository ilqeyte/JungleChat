/// JungleChat — AdMob configuration.
///
/// Uses Google AdMob TEST ads so no real network/account calls are made in
/// development or QA builds. Before shipping to production, swap the app ID and
/// rewarded ad unit for the real ones from the AdMob console.
class AdConfig {
  AdConfig._();

  /// AdMob application ID (TEST id). Also declared in AndroidManifest.xml and
  /// iOS Info.plist via GADApplicationIdentifier.
  static const String adMobAppId = 'ca-app-pub-3940256099942544~3347511713';

  /// Rewarded ad unit (TEST id).
  static const String rewardedAdUnitId =
      'ca-app-pub-3940256099942544/5224354917';
}
