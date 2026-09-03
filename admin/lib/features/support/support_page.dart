import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/widgets.dart';

class SupportPage extends ConsumerStatefulWidget {
  const SupportPage({super.key});

  @override
  ConsumerState<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends ConsumerState<SupportPage> {
  List<Map<String, dynamic>> _convs = [];
  List<Map<String, dynamic>> _messages = [];
  String? _selectedId;
  bool _loadingConvs = true;
  bool _loadingMsg = false;
  String? _error;
  final _msgCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadConvs();
  }

  Future<void> _loadConvs() async {
    setState(() => _loadingConvs = true);
    try {
      final res = await Supabase.instance.client.rpc('admin_list_support_conversations');
      _convs = (res as List).cast<Map<String, dynamic>>();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loadingConvs = false);
    }
  }

  Future<void> _openConv(String id) async {
    setState(() {
      _selectedId = id;
      _loadingMsg = true;
    });
    try {
      await Supabase.instance.client.rpc('admin_mark_support_read',
          params: {'p_conversation': id});
      final res = await Supabase.instance.client
          .from('direct_messages')
          .select('id, sender_id, content, created_at')
          .eq('conversation_id', id)
          .isFilter('deleted_at', null)
          .order('created_at', ascending: true);
      _messages = (res as List).cast<Map<String, dynamic>>();
      // refresh unread badges
      _loadConvs();
    } catch (e) {
      showError(context, 'Could not open conversation: $e');
    } finally {
      if (mounted) setState(() => _loadingMsg = false);
    }
  }

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _selectedId == null) return;
    _msgCtrl.clear();
    try {
      await Supabase.instance.client.rpc('admin_send_support_message',
          params: {'p_conversation': _selectedId, 'p_content': text});
      await _openConv(_selectedId!);
    } catch (e) {
      showError(context, 'Send failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Official support'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadConvs,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!, style: const TextStyle(color: JCColors.danger)))
          : Row(
              children: [
                SizedBox(
                  width: 320,
                  child: _loadingConvs
                      ? const Center(child: CircularProgressIndicator(color: JCColors.accent))
                      : ListView.separated(
                          itemCount: _convs.length,
                          separatorBuilder: (_, _) =>
                              const Divider(color: JCColors.surface2),
                          itemBuilder: (_, i) {
                            final c = _convs[i];
                            final id = c['conversation_id'].toString();
                            final unread = c['unread_count'] as int? ?? 0;
                            return ListTile(
                              selected: id == _selectedId,
                              selectedTileColor: JCColors.surface2,
                              title: Text(c['partner_display_id']?.toString() ?? '—'),
                              subtitle: Text(c['partner_animal']?.toString() ?? '',
                                  style: const TextStyle(color: JCColors.muted)),
                              trailing: unread > 0
                                  ? Chip(
                                      label: Text(unread.toString()),
                                      backgroundColor: JCColors.accent,
                                      visualDensity: VisualDensity.compact,
                                    )
                                  : null,
                              onTap: () => _openConv(id),
                            );
                          },
                        ),
                ),
                const VerticalDivider(width: 1, color: JCColors.surface2),
                Expanded(
                  child: _selectedId == null
                      ? const Center(
                          child: Text('Select a conversation.',
                              style: TextStyle(color: JCColors.muted)))
                      : Column(
                          children: [
                            Expanded(
                              child: _loadingMsg
                                  ? const Center(
                                      child: CircularProgressIndicator(
                                          color: JCColors.accent))
                                  : ListView.builder(
                                      padding: const EdgeInsets.all(16),
                                      itemCount: _messages.length,
                                      itemBuilder: (_, i) {
                                        final m = _messages[i];
                                        return Align(
                                          alignment: Alignment.centerLeft,
                                          child: Container(
                                            margin: const EdgeInsets.only(bottom: 8),
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                              color: JCColors.surface,
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(m['content']?.toString() ?? '',
                                                    style: const TextStyle(
                                                        color: JCColors.text)),
                                                const SizedBox(height: 4),
                                                Text(fmt(m['created_at']),
                                                    style: const TextStyle(
                                                        color: JCColors.muted,
                                                        fontSize: 11)),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _msgCtrl,
                                      decoration: const InputDecoration(
                                        labelText: 'Reply as official support',
                                      ),
                                      onSubmitted: (_) => _send(),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  FilledButton(
                                    onPressed: _send,
                                    child: const Text('Send'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
    );
  }
}
