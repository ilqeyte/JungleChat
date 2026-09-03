import 'dart:io';

import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/app_update.dart';
import '../../services/update_service.dart';

/// Downloads a release APK and hands it to the Android package installer.
///
/// Platform notes (Android 8+):
///  * Installing anything requires the REQUEST_INSTALL_PACKAGES permission.
///    It is a "special" permission: it cannot be granted from a runtime
///    dialog, so `request()` deep-links into the system settings page. The old
///    code asked for `Permission.storage`, which is ignored on Android 13+ and
///    is the wrong permission anyway.
///  * The APK is written to the app's own external files directory, which
///    needs NO storage permission on any Android version, and is shared with
///    the installer through a FileProvider (see MainActivity.kt).
class UpdateDownloader {
  static const MethodChannel _installer = MethodChannel(
    'com.junglechat.app/installer',
  );

  final UpdateService _service = UpdateService();

  /// Build number of the running app (versionCode).
  Future<int> getCurrentVersionCode() async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber) ?? 1;
  }

  /// Version name of the running app.
  Future<String> getCurrentVersionName() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  /// The published release if it is newer than this build, else null.
  Future<AppUpdate?> checkForUpdate() async {
    final latest = await _service.getLatestUpdate();
    if (latest == null) return null;

    final currentCode = await getCurrentVersionCode();
    if (latest.versionCode <= currentCode) return null;

    return latest;
  }

  /// Whether the user must install right now.
  ///
  /// A required release with no grace date blocks immediately. A required
  /// release with a future date only blocks once that date passes, so users
  /// can still skip in the meantime.
  bool isRequiredNow(AppUpdate update) {
    if (!update.isRequired) return false;
    if (update.requiredAfter == null) return true;
    return DateTime.now().isAfter(update.requiredAfter!);
  }

  /// Whether this app is already allowed to install packages.
  Future<bool> hasInstallPermission() async {
    if (!Platform.isAndroid) return true;
    return Permission.requestInstallPackages.isGranted;
  }

  /// Opens the system "install unknown apps" page for this app.
  ///
  /// There is no runtime dialog for this permission — the user toggles it in
  /// Settings and returns via the back button.
  Future<bool> requestInstallPermission() async {
    if (!Platform.isAndroid) return true;

    final status = await Permission.requestInstallPackages.request();
    if (status.isGranted) return true;

    // permission_handler cannot open the special-access screen on every
    // device; fall back to the native side, which launches it directly.
    try {
      final granted = await _installer.invokeMethod<bool>(
        'openInstallSettings',
      );
      return granted ?? false;
    } on MissingPluginException {
      return status.isGranted;
    } on PlatformException {
      return status.isGranted;
    }
  }

  /// Downloads the APK and launches the installer.
  ///
  /// Throws a human-readable message on failure.
  Future<File> downloadAndInstall(
    AppUpdate update, {
    required void Function(DownloadProgress) onProgress,
  }) async {
    final url = update.downloadUrl;
    if (url == null || url.trim().isEmpty) {
      throw Exception('No download link is set for this update.');
    }

    final file = await _service.downloadApk(
      url,
      await _destination(update),
      onProgress,
    );

    await installApk(file.path);
    return file;
  }

  /// Where the APK is written. App-specific external storage: no storage
  /// permission required, and large enough for any realistic APK.
  Future<File> _destination(AppUpdate update) async {
    Directory dir;
    try {
      final external = await getExternalStorageDirectory();
      dir = external ?? await getTemporaryDirectory();
    } catch (_) {
      dir = await getTemporaryDirectory();
    }

    final updatesDir = Directory('${dir.path}/updates');
    if (!await updatesDir.exists()) {
      await updatesDir.create(recursive: true);
    }

    return File('${updatesDir.path}/junglechat-v${update.versionCode}.apk');
  }

  /// Launches the Android package installer for a downloaded APK.
  ///
  /// Prefers the native FileProvider path (reliable on Android 7+ where
  /// file:// URIs are rejected), and falls back to open_filex.
  Future<void> installApk(String filePath) async {
    if (!Platform.isAndroid) {
      throw Exception('In-app updates are only supported on Android.');
    }

    // 1. Native installer via FileProvider.
    try {
      final ok = await _installer.invokeMethod<bool>('installApk', {
        'path': filePath,
      });
      if (ok == true) return;
    } on MissingPluginException {
      // Native side not available; fall through.
    } on PlatformException catch (e) {
      throw Exception(e.message ?? 'Could not start the installer.');
    }

    // 2. Fallback: open_filex (also FileProvider-backed).
    final result = await OpenFilex.open(filePath);
    if (result.type != ResultType.done) {
      throw Exception(
        result.message.isNotEmpty
            ? result.message
            : 'Could not open the installer.',
      );
    }
  }

  /// Deletes previously downloaded APKs so storage does not grow forever.
  Future<void> clearCache() async {
    try {
      Directory dir;
      try {
        final external = await getExternalStorageDirectory();
        dir = external ?? await getTemporaryDirectory();
      } catch (_) {
        dir = await getTemporaryDirectory();
      }
      final updatesDir = Directory('${dir.path}/updates');
      if (await updatesDir.exists()) {
        await updatesDir.delete(recursive: true);
      }
    } catch (_) {
      // Best effort only.
    }
  }
}
