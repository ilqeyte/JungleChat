import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../../services/feedback_service.dart';
import '../auth/welcome_screen.dart';
import '../home/home_tab.dart';

/// Auto-delete timer options
enum AutoDeleteOption {
  off(null),
  hours24(Duration(hours: 24)),
  days7(Duration(days: 7)),
  days30(Duration(days: 30)),
  days90(Duration(days: 90)),
  days180(Duration(days: 180)),
  days365(Duration(days: 365));

  const AutoDeleteOption(this.duration);
  final Duration? duration;

  String get label {
    switch (this) {
      case AutoDeleteOption.off:
        return 'Off';
      case AutoDeleteOption.hours24:
        return '24 hours';
      case AutoDeleteOption.days7:
        return '7 days';
      case AutoDeleteOption.days30:
        return '30 days (1 month)';
      case AutoDeleteOption.days90:
        return '90 days (3 months)';
      case AutoDeleteOption.days180:
        return '180 days (6 months)';
      case AutoDeleteOption.days365:
        return '365 days (12 months)';
    }
  }

  String get description {
    switch (this) {
      case AutoDeleteOption.off:
        return 'Messages are kept forever';
      case AutoDeleteOption.hours24:
        return 'Messages deleted after 24 hours';
      case AutoDeleteOption.days7:
        return 'Messages deleted after 7 days';
      case AutoDeleteOption.days30:
        return 'Messages deleted after 30 days';
      case AutoDeleteOption.days90:
        return 'Messages deleted after 90 days';
      case AutoDeleteOption.days180:
        return 'Messages deleted after 180 days';
      case AutoDeleteOption.days365:
        return 'Messages deleted after 365 days';
    }
  }

  static AutoDeleteOption fromDuration(Duration? duration) {
    if (duration == null) return AutoDeleteOption.off;
    final hours = duration.inHours;
    if (hours == 24) return AutoDeleteOption.hours24;
    if (hours == 24 * 7) return AutoDeleteOption.days7;
    if (hours == 24 * 30) return AutoDeleteOption.days30;
    if (hours == 24 * 90) return AutoDeleteOption.days90;
    if (hours == 24 * 180) return AutoDeleteOption.days180;
    if (hours == 24 * 365) return AutoDeleteOption.days365;
    return AutoDeleteOption.off;
  }

  String? get pgInterval {
    switch (this) {
      case AutoDeleteOption.off:
        return null;
      case AutoDeleteOption.hours24:
        return '24 hours';
      case AutoDeleteOption.days7:
        return '7 days';
      case AutoDeleteOption.days30:
        return '30 days';
      case AutoDeleteOption.days90:
        return '90 days';
      case AutoDeleteOption.days180:
        return '180 days';
      case AutoDeleteOption.days365:
        return '365 days';
    }
  }
}

/// Dialog for selecting auto-delete timer
class AutoDeleteTimerDialog extends ConsumerStatefulWidget {
  final String? conversationId;
  final String? groupId;
  /// Phase 6: when true, the choice is saved as THIS account's default
  /// disappearing-message timer (applies to every new chat). Mutually
  /// exclusive with the per-thread modes above.
  final bool defaultMode;
  final String? title;
  final AutoDeleteOption initialValue;

  const AutoDeleteTimerDialog({
    super.key,
    this.conversationId,
    this.groupId,
    this.defaultMode = false,
    this.title,
    this.initialValue = AutoDeleteOption.off,
  });

  @override
  ConsumerState<AutoDeleteTimerDialog> createState() =>
      _AutoDeleteTimerDialogState();
}

class _AutoDeleteTimerDialogState extends ConsumerState<AutoDeleteTimerDialog> {
  late AutoDeleteOption _selectedOption;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedOption = widget.initialValue;
  }

  Future<void> _save() async {
    if (!widget.defaultMode &&
        widget.conversationId == null &&
        widget.groupId == null) {
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      if (widget.defaultMode) {
        await ref
            .read(authServiceProvider)
            .setDefaultAutoDelete(_selectedOption.pgInterval);
      } else if (widget.conversationId != null) {
        await ref
            .read(chatServiceProvider)
            .setConversationAutoDelete(
              widget.conversationId!,
              _selectedOption.pgInterval,
            );
      } else if (widget.groupId != null) {
        await ref
            .read(groupServiceProvider)
            .setGroupAutoDelete(widget.groupId!, _selectedOption.pgInterval);
      }
      if (!mounted) return;
      if (context.mounted) context.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = SafeErrors.message(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: JCColors.surface,
      title: Text(
        widget.title ?? 'Auto-Delete Timer',
        style: JCTypography.title,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Messages will be automatically deleted after the selected time. This applies to all participants.',
            style: JCTypography.body,
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Text(
              _error!,
              style: JCTypography.secondary.copyWith(color: JCColors.danger),
            ),
          const SizedBox(height: 8),
          RadioGroup<AutoDeleteOption>(
            groupValue: _selectedOption,
            onChanged: (value) {
              FeedbackService.tap();
              if (value != null) {
                setState(() => _selectedOption = value);
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: AutoDeleteOption.values.map((option) {
                return RadioListTile<AutoDeleteOption>(
                  value: option,
                  title: Text(option.label, style: JCTypography.body),
                  subtitle: Text(
                    option.description,
                    style: JCTypography.secondary.copyWith(fontSize: 12),
                  ),
                  activeColor: JCColors.accent,
                  contentPadding: EdgeInsets.zero,
                );
              }).toList(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving
              ? null
              : FeedbackService.click(() => Navigator.pop(context)),
          child: Text('CANCEL', style: JCTypography.secondary),
        ),
        FilledButton(
          onPressed: _saving ? null : FeedbackService.click(_save),
          style: FilledButton.styleFrom(
            backgroundColor: JCColors.accent,
            foregroundColor: Colors.white,
          ),
          child: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(
                  'SAVE',
                  style: JCTypography.secondary.copyWith(color: Colors.white),
                ),
        ),
      ],
    );
  }
}

/// Shows the auto-delete timer dialog
Future<void> showAutoDeleteTimerDialog(
  BuildContext context, {
  String? conversationId,
  String? groupId,
  bool defaultMode = false,
  String? title,
  AutoDeleteOption initialValue = AutoDeleteOption.off,
}) async {
  await showDialog<bool>(
    context: context,
    builder: (ctx) => AutoDeleteTimerDialog(
      conversationId: conversationId,
      groupId: groupId,
      defaultMode: defaultMode,
      title: title,
      initialValue: initialValue,
    ),
  );
}

/// Maps a Postgres interval string (from the default / conversation / group
/// RPCs) to the nearest [AutoDeleteOption]. Used to seed dialogs from the
/// server's current value. Returns [AutoDeleteOption.off] for null / "NULL" /
/// unrecognised inputs.
AutoDeleteOption autoDeleteOptionFromInterval(String? interval) {
  if (interval == null || interval == 'NULL' || interval.trim().isEmpty) {
    return AutoDeleteOption.off;
  }
  final lower = interval.toLowerCase();
  if (lower.contains('24') && (lower.contains('hour') || lower.contains(':'))) {
    return AutoDeleteOption.hours24;
  }
  if (lower.contains('7') && lower.contains('day')) return AutoDeleteOption.days7;
  if (lower.contains('30') && lower.contains('day')) {
    return AutoDeleteOption.days30;
  }
  if (lower.contains('90') && lower.contains('day')) {
    return AutoDeleteOption.days90;
  }
  if (lower.contains('180') && lower.contains('day')) {
    return AutoDeleteOption.days180;
  }
  if (lower.contains('365') && lower.contains('day')) {
    return AutoDeleteOption.days365;
  }
  return AutoDeleteOption.off;
}
