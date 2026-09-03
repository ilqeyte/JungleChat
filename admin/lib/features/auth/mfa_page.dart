import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth_controller.dart';
import '../../shared/widgets.dart';

/// Second-factor screen. Two modes:
///  * enrolling = true  → admin has no TOTP factor yet; we enroll one and show
///                         the QR / secret for the admin's authenticator app.
///  * enrolling = false → admin already enrolled; we just collect a code and
///                         verify against the existing factor.
class MfaPage extends ConsumerStatefulWidget {
  const MfaPage({super.key});

  @override
  ConsumerState<MfaPage> createState() => _MfaPageState();
}

class _MfaPageState extends ConsumerState<MfaPage> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  bool _enrolling = false;
  String? _factorId;
  String? _totpUri;
  String? _secret;

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authControllerProvider);
    _enrolling = auth.enrolling;
    if (_enrolling) _startEnroll();
  }

  Future<void> _startEnroll() async {
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.auth.mfa.enroll(
        factorType: FactorType.totp,
        issuer: 'JungleChat',
        friendlyName: 'JungleChat Admin',
      );
      _factorId = res.id;
      _totpUri = res.totp?.uri;
      _secret = res.totp?.secret;
    } catch (e) {
      setState(() => _error = 'Could not start MFA enrollment: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final code = _code.text.trim().replaceAll(' ', '');
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final factorId = _factorId ?? ref.read(authControllerProvider).factorId;
      if (factorId == null) throw Exception('No MFA factor available.');
      await Supabase.instance.client.auth.mfa.challengeAndVerify(
        factorId: factorId,
        code: code,
      );
      await ref.read(authControllerProvider.notifier).evaluateAfterMfa();
    } catch (e) {
      setState(() => _error = 'Invalid or expired code. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = ref.watch(authControllerProvider).email ?? '';
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: AppCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Two-factor authentication',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: JCColors.text,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _enrolling
                      ? 'Scan this QR code with your authenticator app, then enter the 6-digit code.'
                      : 'Enter the 6-digit code from your authenticator app for $email.',
                  style: const TextStyle(color: JCColors.muted),
                ),
                const SizedBox(height: 18),
                if (_enrolling) ...[
                  if (_totpUri != null)
                    Center(
                      child: QrImageView(
                        data: _totpUri!,
                        version: QrVersions.auto,
                        size: 200,
                        backgroundColor: Colors.white,
                        dataModuleStyle: const QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: Colors.black,
                        ),
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Colors.black,
                        ),
                      ),
                    )
                  else
                    const Center(
                      child: CircularProgressIndicator(color: JCColors.accent),
                    ),
                  if (_secret != null) ...[
                    const SizedBox(height: 12),
                    SelectableText(
                      'Manual key: $_secret',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: JCColors.text),
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: _code,
                  decoration: const InputDecoration(
                    labelText: 'Authentication code',
                    prefixIcon: Icon(Icons.pin),
                  ),
                  keyboardType: TextInputType.number,
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: const TextStyle(color: JCColors.danger)),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : const Text('Verify'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
