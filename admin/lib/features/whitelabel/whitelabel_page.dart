import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/widgets.dart';

class WhiteLabelPage extends ConsumerStatefulWidget {
  const WhiteLabelPage({super.key});

  @override
  ConsumerState<WhiteLabelPage> createState() => _WhiteLabelPageState();
}

class _WhiteLabelPageState extends ConsumerState<WhiteLabelPage> {
  final _appName = TextEditingController();
  final _tagline = TextEditingController();
  final _primary = TextEditingController();
  final _accent = TextEditingController();
  final _bg = TextEditingController();
  final _email = TextEditingController();
  final _terms = TextEditingController();
  final _privacy = TextEditingController();
  bool _reactions = true;
  bool _autoDelete = true;
  bool _appLock = true;
  bool _groups = true;

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('get_app_config');
      final cfg = (res as Map).cast<String, dynamic>();
      _appName.text = _str(cfg['app_name']) ?? 'JungleChat';
      _tagline.text = _str(cfg['tagline']) ?? '';
      final brand = cfg['brand'] as Map? ?? {};
      _primary.text = _str(brand['primary_color']) ?? '#0B0B0B';
      _accent.text = _str(brand['accent_color']) ?? '#8FBF9F';
      _bg.text = _str(brand['background_color']) ?? '#000000';
      final support = cfg['support'] as Map? ?? {};
      _email.text = _str(support['email']) ?? '';
      _terms.text = _str(support['terms_url']) ?? '';
      _privacy.text = _str(support['privacy_url']) ?? '';
      final features = cfg['features'] as Map? ?? {};
      _reactions = features['reactions'] != false;
      _autoDelete = features['auto_delete'] != false;
      _appLock = features['app_lock'] != false;
      _groups = features['groups'] != false;
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? _str(dynamic v) => v?.toString();

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final sb = Supabase.instance.client;
      await sb.rpc('admin_set_app_config',
          params: {'p_key': 'app_name', 'p_value': _appName.text.trim()});
      await sb.rpc('admin_set_app_config',
          params: {'p_key': 'tagline', 'p_value': _tagline.text.trim()});
      await sb.rpc('admin_set_app_config',
          params: {
            'p_key': 'brand',
            'p_value': {
              'primary_color': _primary.text.trim(),
              'accent_color': _accent.text.trim(),
              'background_color': _bg.text.trim(),
            }
          });
      await sb.rpc('admin_set_app_config',
          params: {
            'p_key': 'support',
            'p_value': {
              'email': _email.text.trim(),
              'terms_url': _terms.text.trim(),
              'privacy_url': _privacy.text.trim(),
            }
          });
      await sb.rpc('admin_set_app_config',
          params: {
            'p_key': 'features',
            'p_value': {
              'reactions': _reactions,
              'auto_delete': _autoDelete,
              'app_lock': _appLock,
              'groups': _groups,
            }
          });
      showInfo(context, 'White-label settings saved.');
    } catch (e) {
      showError(context, 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Color? _swatch(String hex) {
    final h = hex.trim().replaceFirst('#', '');
    if (h.length != 6) return null;
    final v = int.tryParse(h, radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('White-label'),
        actions: [
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save),
            label: const Text('Save'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: JCColors.accent))
          : _error != null
              ? Center(child: Text(_error!, style: TextStyle(color: JCColors.danger)))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Wrap(
                    spacing: 24,
                    runSpacing: 24,
                    crossAxisAlignment: WrapCrossAlignment.start,
                    children: [
                      SizedBox(
                        width: 420,
                        child: AppCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SectionHeader('Branding'),
                              const SizedBox(height: 12),
                              TextField(controller: _appName, decoration: const InputDecoration(labelText: 'App name')),
                              const SizedBox(height: 12),
                              TextField(controller: _tagline, decoration: const InputDecoration(labelText: 'Tagline')),
                              const SizedBox(height: 12),
                              _colorField('Primary color', _primary),
                              const SizedBox(height: 12),
                              _colorField('Accent color', _accent),
                              const SizedBox(height: 12),
                              _colorField('Background color', _bg),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 420,
                        child: AppCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SectionHeader('Support & legal'),
                              const SizedBox(height: 12),
                              TextField(controller: _email, decoration: const InputDecoration(labelText: 'Support email')),
                              const SizedBox(height: 12),
                              TextField(controller: _terms, decoration: const InputDecoration(labelText: 'Terms URL')),
                              const SizedBox(height: 12),
                              TextField(controller: _privacy, decoration: const InputDecoration(labelText: 'Privacy URL')),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 420,
                        child: AppCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SectionHeader('Feature toggles'),
                              const SizedBox(height: 8),
                              _toggle('Reactions', _reactions, (v) => setState(() => _reactions = v)),
                              _toggle('Auto-delete timer', _autoDelete, (v) => setState(() => _autoDelete = v)),
                              _toggle('App lock', _appLock, (v) => setState(() => _appLock = v)),
                              _toggle('Groups', _groups, (v) => setState(() => _groups = v)),
                              const SizedBox(height: 8),
                              const Text(
                                'Note: the mobile app reads these values on launch. '
                                'Deep branding (icon, splash) still requires a rebuild.',
                                style: TextStyle(color: JCColors.muted, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _colorField(String label, TextEditingController c) {
    final swatch = _swatch(c.text);
    return TextField(
      controller: c,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: swatch == null
            ? null
            : Container(
                margin: const EdgeInsets.all(8),
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: swatch,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: JCColors.muted),
                ),
              ),
      ),
    );
  }

  Widget _toggle(String label, bool value, void Function(bool) onChanged) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(color: JCColors.text)),
      value: value,
      activeThumbColor: JCColors.accent,
      onChanged: onChanged,
    );
  }
}
