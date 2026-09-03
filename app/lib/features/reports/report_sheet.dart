import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/theme.dart';
import '../../services/feedback_service.dart';
import '../home/home_tab.dart';

/// PRD §30–31 — reporting is one tap away and never asks the user to supply
/// technical details; message/room/user context is attached server-side.
/// The reporter's identity is stored internally only, never shown to admins
/// as part of the report card.
void showReportSheet(
  BuildContext context,
  WidgetRef ref, {
  required String type,
  String? targetUser,
  String? targetMessage,
  String? targetRoom,
  String contextLine = '',
}) {
  final body = TextEditingController();
  bool sending = false;

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: JCColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheet) => Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 22,
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 22,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('REPORT / HELP', style: JCTypography.title),
            if (contextLine.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(contextLine, style: JCTypography.animalId),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: body,
              maxLines: 4,
              maxLength: AppConfig.maxReportLength,
              decoration: const InputDecoration(hintText: 'What happened?'),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: sending
                  ? null
                  : FeedbackService.click(() async {
                      setSheet(() => sending = true);
                      try {
                        await ref
                            .read(socialServiceProvider)
                            .report(
                              type: type,
                              body: body.text.trim(),
                              targetUser: targetUser,
                              targetMessage: targetMessage,
                              targetRoom: targetRoom,
                            );
                        if (!sheetCtx.mounted) return;
                        Navigator.pop(sheetCtx);
                        ScaffoldMessenger.of(sheetCtx).showSnackBar(
                          const SnackBar(
                            content: Text('Report sent. Thank you.'),
                          ),
                        );
                      } catch (_) {
                        setSheet(() => sending = false);
                        ScaffoldMessenger.of(sheetCtx).showSnackBar(
                          const SnackBar(
                            content: Text('Could not send. Try again shortly.'),
                          ),
                        );
                      }
                    }),
              child: Text(sending ? 'SENDING…' : 'SEND REPORT'),
            ),
          ],
        ),
      ),
    ),
  ).whenComplete(body.dispose);
}
