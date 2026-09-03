import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/widgets.dart';

class UpdatesPage extends ConsumerStatefulWidget {
  const UpdatesPage({super.key});

  @override
  ConsumerState<UpdatesPage> createState() => _UpdatesPageState();
}

class _UpdatesPageState extends ConsumerState<UpdatesPage> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('admin_list_updates');
      _rows = (res as List).cast<Map<String, dynamic>>();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final codeCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final changeCtrl = TextEditingController();
    bool required = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New app update'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: codeCtrl,
              decoration: const InputDecoration(labelText: 'Version code (int, e.g. 18)'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 10),
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Version name (e.g. 1.2.0)')),
            const SizedBox(height: 10),
            TextField(controller: changeCtrl, decoration: const InputDecoration(labelText: 'Changelog'), maxLines: 3),
            const SizedBox(height: 10),
            StatefulBuilder(
              builder: (c, set) => CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Required update', style: TextStyle(color: JCColors.text)),
                value: required,
                onChanged: (v) => set(() => required = v ?? false),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
        ],
      ),
    );
    if (ok != true) return;
    final code = int.tryParse(codeCtrl.text.trim());
    if (code == null) {
      showError(context, 'Version code must be a number.');
      return;
    }
    try {
      await Supabase.instance.client.rpc('admin_create_update',
          params: {
            'p_version_code': code,
            'p_version_name': nameCtrl.text.trim(),
            'p_changelog': changeCtrl.text.trim(),
            'p_is_required': required,
          });
      showInfo(context, 'Update created. Publish it with a download URL to go live.');
      await _load();
    } catch (e) {
      showError(context, 'Create failed: $e');
    }
  }

  Future<void> _publish(String id) async {
    final urlCtrl = TextEditingController();
    final sizeCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Publish update'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(labelText: 'APK download URL (https://)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: sizeCtrl,
              decoration: const InputDecoration(labelText: 'File size in bytes (optional)'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Publish')),
        ],
      ),
    );
    if (ok != true) return;
    final size = int.tryParse(sizeCtrl.text.trim()) ?? 0;
    try {
      await Supabase.instance.client.rpc('admin_publish_update',
          params: {
            'p_update_id': id,
            'p_download_url': urlCtrl.text.trim(),
            'p_file_size': size,
          });
      showInfo(context, 'Update published and live.');
      await _load();
    } catch (e) {
      showError(context, 'Publish failed: $e');
    }
  }

  Future<void> _setActive(String id) async {
    try {
      await Supabase.instance.client.rpc('admin_set_active_update', params: {'p_update_id': id});
      showInfo(context, 'Set as active release.');
      await _load();
    } catch (e) {
      showError(context, 'Failed: $e');
    }
  }

  Future<void> _toggleRequired(String id, bool current) async {
    try {
      await Supabase.instance.client.rpc('admin_toggle_update_required',
          params: {'p_update_id': id, 'p_is_required': !current});
      await _load();
    } catch (e) {
      showError(context, 'Failed: $e');
    }
  }

  Future<void> _delete(String id) async {
    final ok = await confirmDialog(context, 'Delete update', 'Remove this update row permanently?');
    if (!ok) return;
    try {
      await Supabase.instance.client.rpc('admin_delete_update_cascade', params: {'p_update_id': id});
      showInfo(context, 'Update deleted.');
      await _load();
    } catch (e) {
      showError(context, 'Delete failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('App updates'),
        actions: [
          FilledButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.add),
            label: const Text('New update'),
          ),
          const SizedBox(width: 8),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: JCColors.accent))
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: JCColors.danger)))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: AppCard(
                    padding: const EdgeInsets.all(8),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('Version')),
                          DataColumn(label: Text('Name')),
                          DataColumn(label: Text('Active')),
                          DataColumn(label: Text('Required')),
                          DataColumn(label: Text('Published')),
                          DataColumn(label: Text('Actions')),
                        ],
                        rows: _rows.map((u) {
                          final id = u['id'].toString();
                          final active = u['is_active'] == true;
                          final required = u['is_required'] == true;
                          return DataRow(
                            cells: [
                              DataCell(Text(u['version_code']?.toString() ?? '—')),
                              DataCell(Text(u['version_name']?.toString() ?? '—')),
                              DataCell(active
                                  ? const Chip(label: Text('LIVE'), backgroundColor: JCColors.accent)
                                  : const Text('—')),
                              DataCell(Text(required ? 'Yes' : 'No')),
                              DataCell(Text(fmt(u['published_at']))),
                              DataCell(Wrap(
                                spacing: 4,
                                children: [
                                  if (!active)
                                    TextButton(onPressed: () => _publish(id), child: const Text('Publish')),
                                  if (!active)
                                    TextButton(onPressed: () => _setActive(id), child: const Text('Set active')),
                                  TextButton(
                                    onPressed: () => _toggleRequired(id, required),
                                    child: const Text('Toggle req.'),
                                  ),
                                  TextButton(
                                    onPressed: () => _delete(id),
                                    child: const Text('Delete', style: TextStyle(color: JCColors.danger)),
                                  ),
                                ],
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
