import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../models/app_update.dart';
import '../../services/feedback_service.dart';
import '../../services/update_service.dart';
import 'update_downloader.dart';

/// Full-screen update screen with the download + install flow.
///
/// Shows Adam's "What's New", downloads the APK, then hands it to the Android
/// package installer. The installer runs as a system overlay on top of this
/// task, so the user never leaves the app.
///
/// The one genuine interruption is Android's "install unknown apps" switch:
/// it is a special permission that can only be granted in system settings, so
/// we deep-link there and resume automatically when the user comes back.
///
/// [dismissable] selects the optional-release mode: title changes, the back
/// gesture works and a LATER button appears. The gate uses the blocking mode
/// for required releases whose grace period has passed.
class RequiredUpdateScreen extends StatefulWidget {
  final AppUpdate update;
  final bool dismissable;

  const RequiredUpdateScreen({
    super.key,
    required this.update,
    this.dismissable = false,
  });

  @override
  State<RequiredUpdateScreen> createState() => _RequiredUpdateScreenState();
}

enum _Phase { idle, downloading, installing, error }

class _RequiredUpdateScreenState extends State<RequiredUpdateScreen>
    with WidgetsBindingObserver {
  final UpdateDownloader _downloader = UpdateDownloader();

  _Phase _phase = _Phase.idle;
  DownloadProgress _progress = const DownloadProgress(0, 0);
  String? _error;

  /// Set when a download was already requested, so returning from the
  /// settings screen resumes it instead of asking the user to tap again.
  bool _resumeOnReturn = false;

  /// What the device is actually running, shown next to the available
  /// release so a version-code mismatch is always visible.
  String _installedLabel = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadInstalledLabel();
  }

  Future<void> _loadInstalledLabel() async {
    try {
      final name = await _downloader.getCurrentVersionName();
      final code = await _downloader.getCurrentVersionCode();
      if (!mounted) return;
      setState(() => _installedLabel = '$name ($code)');
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _resumeOnReturn) {
      _resumeOnReturn = false;
      // Re-check the permission now that we are back, then carry on.
      unawaited(_start(skipPermissionCheck: false));
    }
  }

  Future<void> _start({bool skipPermissionCheck = false}) async {
    if (_phase == _Phase.downloading || _phase == _Phase.installing) return;

    if (!skipPermissionCheck) {
      final granted = await _downloader.hasInstallPermission();
      if (!granted) {
        _resumeOnReturn = true;
        await _downloader.requestInstallPermission();
        // The settings screen covers the app; the resume handler above takes
        // over if the user switches the toggle on and comes back.
        if (!mounted) return;
        // Give the OS a moment to settle the settings transition.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!mounted) return;
        if (!await _downloader.hasInstallPermission()) {
          setState(() {
            _phase = _Phase.error;
            _error =
                'Allow "Install unknown apps" for JungleChat to '
                'continue, then tap Retry.';
          });
          return;
        }
      }
    }

    await _downloadAndInstall();
  }

  Future<void> _downloadAndInstall() async {
    setState(() {
      _phase = _Phase.downloading;
      _progress = const DownloadProgress(0, 0);
      _error = null;
    });

    try {
      await _downloader.downloadAndInstall(
        widget.update,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );

      if (!mounted) return;
      // The installer is now on screen. Stay in this state: if the user
      // cancels it, they come back here and can try again.
      setState(() => _phase = _Phase.installing);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e.message ?? 'Could not start the installer.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = _clean(e.toString());
      });
    }
  }

  String _clean(String raw) {
    final text = raw.replaceFirst(RegExp(r'^Exception:\s*'), '');
    return text.isEmpty ? 'Something went wrong. Please try again.' : text;
  }

  String _progressLabel() {
    final mb = (_progress.received / 1024 / 1024);
    if (_progress.hasTotal) {
      final totalMb = _progress.total / 1024 / 1024;
      return 'Downloading... ${(_progress.ratio * 100).toInt()}% '
          '(${mb.toStringAsFixed(1)} / ${totalMb.toStringAsFixed(1)} MB)';
    }
    return 'Downloading... ${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final busy = _phase == _Phase.downloading || _phase == _Phase.installing;

    return PopScope(
      canPop: widget.dismissable && !busy,
      child: Scaffold(
        backgroundColor: JCColors.background,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.system_update,
                    size: 72,
                    color: JCColors.accent,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    widget.dismissable ? 'Update Available' : 'Update Required',
                    style: JCTypography.title.copyWith(fontSize: 24),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Version ${widget.update.versionName} '
                    '(${widget.update.versionCode}) is available.',
                    style: JCTypography.body,
                    textAlign: TextAlign.center,
                  ),
                  if (_installedLabel.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Installed: $_installedLabel',
                      style: JCTypography.secondary,
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 20),

                  // What's New — the text Adam wrote when publishing.
                  if (widget.update.changelog.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: JCColors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: JCColors.outline),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "WHAT'S NEW",
                            style: JCTypography.secondary.copyWith(
                              fontSize: 11,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            widget.update.changelog,
                            style: JCTypography.body.copyWith(fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 32),

                  if (_phase == _Phase.downloading) ...[
                    LinearProgressIndicator(
                      value: _progress.hasTotal ? _progress.ratio : null,
                      backgroundColor: JCColors.outline,
                      valueColor: const AlwaysStoppedAnimation(JCColors.accent),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _progressLabel(),
                      style: JCTypography.secondary.copyWith(fontSize: 13),
                    ),
                  ] else if (_phase == _Phase.installing) ...[
                    Text(
                      'Starting installer...',
                      style: JCTypography.secondary.copyWith(fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: FeedbackService.click(_downloadAndInstall),
                        child: Text(
                          'INSTALL AGAIN',
                          style: JCTypography.secondary,
                        ),
                      ),
                    ),
                  ] else ...[
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: busy
                            ? null
                            : FeedbackService.click(() => _start()),
                        style: FilledButton.styleFrom(
                          backgroundColor: JCColors.accent,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: Text(
                          'UPDATE NOW',
                          style: JCTypography.secondary.copyWith(
                            color: Colors.white,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                    if (widget.dismissable)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: TextButton(
                          onPressed: FeedbackService.click(
                            () => Navigator.of(context).maybePop(),
                          ),
                          child: Text('LATER', style: JCTypography.secondary),
                        ),
                      ),
                  ],

                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: JCTypography.secondary.copyWith(
                        color: JCColors.danger,
                        fontSize: 13,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: FeedbackService.click(() => _start()),
                      child: Text('RETRY', style: JCTypography.secondary),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
