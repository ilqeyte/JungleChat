import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../services/feedback_service.dart';

/// Horizontal swipe-to-reply wrapper (WhatsApp-style). Dragging right
/// reveals a reply arrow; releasing past the threshold triggers [onReply].
class SwipeToReply extends StatefulWidget {
  final VoidCallback onReply;
  final Widget child;

  const SwipeToReply({super.key, required this.onReply, required this.child});

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> {
  static const _threshold = 64.0;
  static const _maxOffset = 88.0;
  double _drag = 0;

  @override
  Widget build(BuildContext context) {
    final showArrow = _drag > 12;
    return Stack(
      children: [
        Positioned.fill(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Opacity(
                opacity: showArrow ? (_drag / _threshold).clamp(0.0, 1.0) : 0,
                child: const Icon(
                  Icons.reply_rounded,
                  size: 20,
                  color: JCColors.accent,
                ),
              ),
            ),
          ),
        ),
        GestureDetector(
          // Horizontal drags only — vertical list scrolling is unaffected.
          onHorizontalDragUpdate: (d) => setState(
            () => _drag = (_drag + d.delta.dx).clamp(0.0, _maxOffset),
          ),
          onHorizontalDragEnd: (d) {
            final fired = _drag >= _threshold;
            setState(() => _drag = 0);
            if (fired) {
              FeedbackService.tap();
              widget.onReply();
            }
          },
          onHorizontalDragCancel: () => setState(() => _drag = 0),
          child: Transform.translate(
            offset: Offset(_drag, 0),
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

/// Quick reactions shown in the long-press action sheet.
const List<String> kQuickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Expanded grid for "customize" (the "+" button).
const List<String> kExtendedReactions = [
  '👍',
  '❤️',
  '😂',
  '😮',
  '😢',
  '🙏',
  '🔥',
  '👏',
  '🥰',
  '😡',
  '🤯',
  '🥳',
  '😴',
  '🤔',
  '😱',
  '💪',
  '✅',
  '❌',
  '⭐',
  '🎉',
  '💯',
  '👀',
  '🤝',
  '🕊️',
  '🐱',
  '🐶',
  '🦉',
  '🦊',
  '🐺',
  '🐼',
  '🦁',
  '🐯',
];

/// Reaction picker: quick row + expandable grid + a custom field for ANY
/// emoji from the keyboard. Returns the chosen emoji (non-empty), or null
/// when dismissed.
Future<String?> showReactionPicker(BuildContext context) {
  var expanded = false;
  final customCtrl = TextEditingController();
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: JCColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) {
      return StatefulBuilder(
        builder: (sheetCtx, setSheet) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final e in kQuickReactions)
                      InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: FeedbackService.click(() {
                          Navigator.pop(sheetCtx, e);
                        }),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(e, style: const TextStyle(fontSize: 28)),
                        ),
                      ),
                    InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: FeedbackService.click(() {
                        FeedbackService.tap();
                        setSheet(() => expanded = !expanded);
                      }),
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(
                          Icons.add_rounded,
                          size: 24,
                          color: JCColors.accent,
                        ),
                      ),
                    ),
                  ],
                ),
                if (expanded) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: GridView.count(
                      crossAxisCount: 8,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        for (final e in kExtendedReactions)
                          InkWell(
                            borderRadius: BorderRadius.circular(24),
                            onTap: FeedbackService.click(() {
                              Navigator.pop(sheetCtx, e);
                            }),
                            child: Center(
                              child: Text(
                                e,
                                style: const TextStyle(fontSize: 24),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Custom: any emoji typed/pasted from the keyboard.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: customCtrl,
                            maxLength: 16,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 22),
                            decoration: const InputDecoration(
                              counterText: '',
                              hintText: 'Custom emoji',
                              isDense: true,
                            ),
                            onSubmitted: (v) {
                              final t = v.trim();
                              if (t.isNotEmpty) Navigator.pop(sheetCtx, t);
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: FeedbackService.click(() {
                            final t = customCtrl.text.trim();
                            if (t.isNotEmpty) Navigator.pop(sheetCtx, t);
                          }),
                          child: const Text('USE'),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      );
    },
  ).then((v) {
    customCtrl.dispose();
    return v;
  });
}

/// One aggregated reaction chip under a bubble.
class ReactionChipData {
  final String emoji;
  final int count;
  final bool mine;

  const ReactionChipData({
    required this.emoji,
    required this.count,
    required this.mine,
  });
}

/// Bucket the flat 'msgId|userId' -> emoji reaction map into per-message
/// sub-maps in ONE pass. Callers should do this ONCE per rebuild (NOT once
/// per message — that would make reaction updates O(messages × reactions)
/// per frame and tank list scroll performance).
///
/// Returns a map keyed by message id; the inner map is the same
/// 'userId -> emoji' shape, but scoped to that message.
Map<String, Map<String, String>> bucketReactionsByMessage(
  Map<String, String> reactions,
) {
  final out = <String, Map<String, String>>{};
  reactions.forEach((key, emoji) {
    final sep = key.indexOf('|');
    if (sep <= 0) return;
    final msgId = key.substring(0, sep);
    final userId = key.substring(sep + 1);
    final bucket = out[msgId];
    if (bucket == null) {
      out[msgId] = {userId: emoji};
    } else {
      bucket[userId] = emoji;
    }
  });
  return out;
}

/// Aggregate a single message's reaction sub-map into chips. Cheap: the
/// inner map is already scoped to this message id (see bucketReactionsByMessage).
List<ReactionChipData> aggregateReactionsForMessage({
  required Map<String, String> messageReactions,
  required String myId,
}) {
  if (messageReactions.isEmpty) return const [];
  final perEmoji = <String, int>{};
  var mine = '';
  messageReactions.forEach((uid, emoji) {
    perEmoji[emoji] = (perEmoji[emoji] ?? 0) + 1;
    if (uid == myId && emoji.isNotEmpty) mine = emoji;
  });
  final list =
      perEmoji.entries
          .map(
            (e) => ReactionChipData(
              emoji: e.key,
              count: e.value,
              mine: e.key == mine,
            ),
          )
          .toList()
        ..sort((a, b) => b.count.compareTo(a.count));
  return list;
}

/// Backwards-compatible wrapper: walks the flat map for a single message.
/// Prefer aggregateReactionsForMessage over a pre-bucketed map.
List<ReactionChipData> aggregateReactions({
  required String messageId,
  required String myId,
  required Map<String, String> reactions,
}) {
  final scoped = <String, String>{};
  final prefix = '$messageId|';
  reactions.forEach((k, v) {
    if (k.startsWith(prefix)) scoped[k.substring(prefix.length)] = v;
  });
  return aggregateReactionsForMessage(
    messageReactions: scoped,
    myId: myId,
  );
}

/// Row of reaction chips under a bubble (tap toggles my reaction).
class ReactionChips extends StatelessWidget {
  final List<ReactionChipData> chips;
  final ValueChanged<String> onTap;

  const ReactionChips({super.key, required this.chips, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox();
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Wrap(
        spacing: 6,
        children: [
          for (final c in chips)
            GestureDetector(
              onTap: FeedbackService.click(() => onTap(c.emoji)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: c.mine
                      ? JCColors.accentDim.withValues(alpha: .8)
                      : JCColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: c.mine ? JCColors.accent : JCColors.outline,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(c.emoji, style: const TextStyle(fontSize: 13)),
                    if (c.count > 1) ...[
                      const SizedBox(width: 3),
                      Text(
                        '${c.count}',
                        style: JCTypography.secondary.copyWith(fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shared clipboard-copy helper for the action sheets.
void copyMessage(BuildContext context, String content) {
  Clipboard.setData(ClipboardData(text: content));
  ScaffoldMessenger.of(context)
      .showSnackBar(const SnackBar(content: Text('Message copied.')));
}
