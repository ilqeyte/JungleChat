import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/app_update.dart';
import '../../services/feedback_service.dart';
import '../../services/update_service.dart';
import 'update_downloader.dart';

/// Dismissible prompt for an optional release.
///
/// Same download-and-install path as [RequiredUpdateScreen], but the user can
/// postpone with LATER.
class UpdateAvailableDialog extends StatefulWidget {
  final AppUpdate update;

  const UpdateAvailableDialog({super.key, required this.update});

  @override
  State<UpdateAvailableDialog> createState() => _UpdateAvailableDialogState();
}

class _UpdateAvailableDialogState extends State<UpdateAvailableDialog> {
  final UpdateDownloader _downloader = UpdateDownloader();

  bool _downloading = false;
  bool _installing = false;
  DownloadProgress _progress = const DownloadProgress(0, 0);
  String? _error;

  Future<void> _start() async {
    if (_downloading || _installing) return;

    if (!await _downloader.hasInstallPermission()) {
      await _downloader.requestInstallPermission();
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      if (!await _downloader.hasInstallPermission()) {
        setState(
          () => _error =
              'Allow "Install unknown apps" for JungleChat, then try again.',
        );
        return;
      }
    }

    setState(() {
      _downloading = true;
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
      setState(() {
        _downloading = false;
        _installing = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      });
    }
  }

  String _label() {
    final mb = _progress.received / 1024 / 1024;
    if (_progress.hasTotal) {
      final totalMb = _progress.total / 1024 / 1024;
      return '${(_progress.ratio * 100).toInt()}% '
          '(${mb.toStringAsFixed(1)} / ${totalMb.toStringAsFixed(1)} MB)';
    }
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final busy = _downloading || _installing;

    return PopScope(
      canPop: !_downloading,
      child: AlertDialog(
        backgroundColor: JCColors.surface,
        title: Row(
          children: [
            const Icon(Icons.system_update, color: JCColors.accent),
            const SizedBox(width: 8),
            Text('Update Available', style: JCTypography.title),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Version ${widget.update.versionName}',
                style: JCTypography.body.copyWith(fontWeight: FontWeight.w600),
              ),
              if (widget.update.changelog.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(widget.update.changelog, style: JCTypography.secondary),
              ],
              if (_downloading) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: _progress.hasTotal ? _progress.ratio : null,
                  backgroundColor: JCColors.outline,
                  valueColor: const AlwaysStoppedAnimation(JCColors.accent),
                ),
                const SizedBox(height: 6),
                Text(
                  _label(),
                  style: JCTypography.secondary.copyWith(fontSize: 12),
                ),
              ],
              if (_installing) ...[
                const SizedBox(height: 12),
                Text(
                  'The installer is opening...',
                  style: JCTypography.secondary.copyWith(fontSize: 12),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: JCTypography.secondary.copyWith(
                    color: JCColors.danger,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (!busy)
            TextButton(
              onPressed: FeedbackService.click(() => Navigator.pop(context)),
              child: Text('LATER', style: JCTypography.secondary),
            ),
          FilledButton(
            onPressed: busy ? null : FeedbackService.click(_start),
            style: FilledButton.styleFrom(backgroundColor: JCColors.accent),
            child: Text(
              _installing ? 'INSTALL AGAIN' : 'UPDATE',
              style: JCTypography.secondary.copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
