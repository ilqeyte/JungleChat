import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';

export '../core/theme.dart';
export 'package:flutter_riverpod/flutter_riverpod.dart';

class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Card(child: Padding(padding: padding, child: child));
  }
}

class StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const StatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: JCColors.accent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: JCColors.muted, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: JCColors.text,
            ),
          ),
        ],
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? action;
  const SectionHeader(this.title, {super.key, this.action});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: JCColors.text,
          ),
        ),
        ?action,
      ],
    );
  }
}

class StatusChip extends StatelessWidget {
  final String status;
  const StatusChip(this.status, {super.key});

  Color _color() {
    switch (status.toLowerCase()) {
      case 'active':
        return JCColors.accent;
      case 'banned':
        return JCColors.danger;
      case 'suspended':
        return JCColors.warn;
      case 'muted':
        return Colors.amber;
      default:
        return JCColors.muted;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(status,
          style: const TextStyle(color: Colors.black, fontSize: 12)),
      backgroundColor: _color(),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

void showError(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), backgroundColor: JCColors.danger),
  );
}

void showInfo(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

Future<bool> confirmDialog(
  BuildContext context,
  String title,
  String body,
) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: JCColors.danger),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Confirm'),
        ),
      ],
    ),
  );
  return result ?? false;
}

String fmt(dynamic value) {
  if (value == null) return '—';
  try {
    return DateFormat.yMd()
        .add_Hm()
        .format(DateTime.parse(value as String));
  } catch (_) {
    return value.toString();
  }
}

String jsonFmt(dynamic value) {
  if (value == null) return '—';
  if (value is Map || value is List) return value.toString();
  return value.toString();
}
