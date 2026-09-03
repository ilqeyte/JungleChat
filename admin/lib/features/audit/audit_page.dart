import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/widgets.dart';

class AuditPage extends ConsumerStatefulWidget {
  const AuditPage({super.key});

  @override
  ConsumerState<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends ConsumerState<AuditPage> {
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
      final res = await Supabase.instance.client.rpc('admin_list_audit_log',
          params: {'p_limit': 200});
      _rows = (res as List).cast<Map<String, dynamic>>();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audit log'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Refresh'),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: JCColors.accent))
          : _error != null
              ? Center(child: Text(_error!, style: TextStyle(color: JCColors.danger)))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: AppCard(
                    child: _rows.isEmpty
                        ? const Text('No audit entries.', style: TextStyle(color: JCColors.muted))
                        : ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _rows.length,
                            separatorBuilder: (_, _) => const Divider(color: JCColors.surface2),
                            itemBuilder: (_, i) {
                              final a = _rows[i];
                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.circle, size: 10, color: JCColors.accent),
                                title: Text(a['event']?.toString() ?? '',
                                    style: const TextStyle(color: JCColors.text, fontSize: 14)),
                                subtitle: Text(jsonFmt(a['details']),
                                    style: const TextStyle(color: JCColors.muted, fontSize: 12)),
                                trailing: Text(fmt(a['created_at']),
                                    style: const TextStyle(color: JCColors.muted, fontSize: 12)),
                              );
                            },
                          ),
                  ),
                ),
    );
  }
}
