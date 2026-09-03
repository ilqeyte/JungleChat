import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/widgets.dart';

class UsersPage extends ConsumerStatefulWidget {
  const UsersPage({super.key});

  @override
  ConsumerState<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends ConsumerState<UsersPage> {
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
      final res = await Supabase.instance.client.rpc('admin_list_users');
      _rows = (res as List).cast<Map<String, dynamic>>();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setStatus(String userId, String status, {String? reason}) async {
    try {
      await Supabase.instance.client.rpc('admin_set_user_status',
          params: {'p_target': userId, 'p_status': status, 'p_reason': reason ?? ''});
      showInfo(context, 'User set to "$status".');
      await _load();
    } catch (e) {
      showError(context, 'Action failed: $e');
    }
  }

  Future<void> _delete(String userId) async {
    final ok = await confirmDialog(
      context,
      'Permanently delete user',
      'This permanently removes the user and all of their data through the '
      'admin-hard-delete-user edge function. This cannot be undone. Continue?',
    );
    if (!ok) return;
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'admin-hard-delete-user',
        body: {'userId': userId},
      );
      final status = res.status;
      if (status >= 200 && status < 300) {
        showInfo(context, 'User permanently deleted.');
      } else {
        final code = res.data is Map ? (res.data as Map)['error']?.toString() : null;
        showError(context, 'Delete failed: ${code ?? status}');
      }
      await _load();
    } catch (e) {
      showError(context, 'Delete failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Users'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: 'Refresh',
          ),
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
                          DataColumn(label: Text('Animal')),
                          DataColumn(label: Text('Animal ID')),
                          DataColumn(label: Text('Status')),
                          DataColumn(label: Text('Open to talk')),
                          DataColumn(label: Text('Created')),
                          DataColumn(label: Text('Actions')),
                        ],
                        rows: _rows.map((u) {
                          return DataRow(
                            cells: [
                              DataCell(Text(u['animal']?.toString() ?? '—')),
                              DataCell(Text(
                                  u['display_animal_id']?.toString() ?? '—')),
                              DataCell(StatusChip(u['status']?.toString() ?? 'unknown')),
                              DataCell(Text(u['open_to_talk'] == true ? 'Yes' : 'No')),
                              DataCell(Text(fmt(u['created_at']))),
                              DataCell(
                                PopupMenuButton<String>(
                                  color: JCColors.surface2,
                                  onSelected: (a) {
                                    final id = u['user_id'] as String;
                                    switch (a) {
                                      case 'active':
                                        _setStatus(id, 'active');
                                      case 'muted':
                                        _setStatus(id, 'muted');
                                      case 'suspended':
                                        _setStatus(id, 'suspended');
                                      case 'banned':
                                        _setStatus(id, 'banned');
                                      case 'delete':
                                        _delete(id);
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    const PopupMenuItem(
                                        value: 'active', child: Text('Set active')),
                                    const PopupMenuItem(
                                        value: 'muted', child: Text('Mute')),
                                    const PopupMenuItem(
                                        value: 'suspended', child: Text('Suspend')),
                                    const PopupMenuItem(
                                        value: 'banned', child: Text('Ban')),
                                    const PopupMenuItem(
                                        value: 'delete',
                                        child: Text('Delete permanently')),
                                  ],
                                  child: const Icon(Icons.more_vert,
                                      color: JCColors.text),
                                ),
                              ),
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
