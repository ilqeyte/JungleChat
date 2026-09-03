import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/widgets.dart';

class ReportsPage extends ConsumerStatefulWidget {
  const ReportsPage({super.key});

  @override
  ConsumerState<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends ConsumerState<ReportsPage> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  String _statusFilter = 'open';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('admin_list_reports',
          params: {'p_status': _statusFilter, 'p_limit': 200});
      _rows = (res as List).cast<Map<String, dynamic>>();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resolve(Map<String, dynamic> r) async {
    final noteCtrl = TextEditingController();
    String choice = 'resolved';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Resolve report'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: choice,
              decoration: const InputDecoration(labelText: 'New status'),
              items: const [
                DropdownMenuItem(value: 'investigating', child: Text('Investigating')),
                DropdownMenuItem(value: 'resolved', child: Text('Resolved')),
                DropdownMenuItem(value: 'dismissed', child: Text('Dismissed')),
              ],
              onChanged: (v) => choice = v ?? choice,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Supabase.instance.client.rpc('admin_resolve_report',
          params: {
            'p_report': r['id'],
            'p_status': choice,
            'p_note': noteCtrl.text.trim(),
          });
      showInfo(context, 'Report marked $choice.');
      await _load();
    } catch (e) {
      showError(context, 'Resolve failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          DropdownButton<String>(
            value: _statusFilter,
            dropdownColor: JCColors.surface2,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: 'open', child: Text('Open')),
              DropdownMenuItem(value: 'investigating', child: Text('Investigating')),
              DropdownMenuItem(value: 'resolved', child: Text('Resolved')),
              DropdownMenuItem(value: 'dismissed', child: Text('Dismissed')),
            ],
            onChanged: (v) {
              if (v != null) {
                _statusFilter = v;
                _load();
              }
            },
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: JCColors.accent))
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: JCColors.danger)))
              : _rows.isEmpty
                  ? const Center(
                      child: Text('No reports in this state.',
                          style: TextStyle(color: JCColors.muted)))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: AppCard(
                        padding: const EdgeInsets.all(8),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columns: const [
                              DataColumn(label: Text('Ref')),
                              DataColumn(label: Text('Type')),
                              DataColumn(label: Text('Status')),
                              DataColumn(label: Text('Reported')),
                              DataColumn(label: Text('Body')),
                              DataColumn(label: Text('Created')),
                              DataColumn(label: Text('Actions')),
                            ],
                            rows: _rows.map((r) {
                              final body = r['body']?.toString() ?? '';
                              return DataRow(
                                cells: [
                                  DataCell(Text(r['human_ref']?.toString() ?? '—')),
                                  DataCell(Text(r['type']?.toString() ?? '—')),
                                  DataCell(StatusChip(r['status']?.toString() ?? 'unknown')),
                                  DataCell(Text(r['reported_animal']?.toString() ?? '—')),
                                  DataCell(ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 320),
                                    child: Text(body,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(color: JCColors.text)),
                                  )),
                                  DataCell(Text(fmt(r['created_at']))),
                                  DataCell(TextButton(
                                    onPressed: () => _resolve(r),
                                    child: const Text('Resolve'),
                                  )),
                                ],
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    ),
    );
  }
}
