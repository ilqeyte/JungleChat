import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/widgets.dart';

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  bool _loading = true;
  String? _error;
  int _users = 0;
  int _openReports = 0;
  int _support = 0;
  int _unread = 0;
  List<Map<String, dynamic>> _audit = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final sb = Supabase.instance.client;
    try {
      final users = await sb.rpc('admin_list_users') as List;
      final reports = await sb.rpc('admin_list_reports',
          params: {'p_status': 'open', 'p_limit': 200}) as List;
      final convs = await sb.rpc('admin_list_support_conversations') as List;
      final audit = await sb.rpc('admin_list_audit_log',
          params: {'p_limit': 8}) as List;
      _users = users.length;
      _openReports = reports.length;
      _support = convs.length;
      _unread = convs.fold<int>(
          0, (sum, c) => sum + (c['unread_count'] as int? ?? 0));
      _audit = audit.cast<Map<String, dynamic>>();
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
        title: const Text('Dashboard'),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader('Overview'),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        children: [
                          SizedBox(
                            width: 220,
                            child: StatCard(
                              label: 'Registered users',
                              value: _users.toString(),
                              icon: Icons.people_outline,
                            ),
                          ),
                          SizedBox(
                            width: 220,
                            child: StatCard(
                              label: 'Open reports',
                              value: _openReports.toString(),
                              icon: Icons.flag_outlined,
                            ),
                          ),
                          SizedBox(
                            width: 220,
                            child: StatCard(
                              label: 'Support threads',
                              value: _support.toString(),
                              icon: Icons.support_agent_outlined,
                            ),
                          ),
                          SizedBox(
                            width: 220,
                            child: StatCard(
                              label: 'Unread messages',
                              value: _unread.toString(),
                              icon: Icons.mark_chat_unread_outlined,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      const SectionHeader('Recent admin activity'),
                      const SizedBox(height: 12),
                      AppCard(
                        child: _audit.isEmpty
                            ? const Text('No activity yet.',
                                style: TextStyle(color: JCColors.muted))
                            : ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: _audit.length,
                                separatorBuilder: (_, _) =>
                                    const Divider(color: JCColors.surface2),
                                itemBuilder: (_, i) {
                                  final a = _audit[i];
                                  return ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Icons.circle,
                                        size: 10, color: JCColors.accent),
                                    title: Text(a['event']?.toString() ?? '',
                                        style: const TextStyle(
                                            color: JCColors.text, fontSize: 14)),
                                    subtitle: Text(fmt(a['created_at']),
                                        style: const TextStyle(
                                            color: JCColors.muted, fontSize: 12)),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
    );
  }
}
