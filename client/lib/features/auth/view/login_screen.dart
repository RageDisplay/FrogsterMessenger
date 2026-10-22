/// Sign-in and registration.
library;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../ui/theme/app_theme.dart';
import '../../../ui/theme/pond_colors.dart';
import '../../../ui/widgets/brand_mark.dart';

/// What the user entered on the sign-in screen.
class LoginRequest {
  const LoginRequest({
    required this.server,
    required this.fingerprint,
    required this.username,
    required this.password,
    required this.register,
  });

  /// Server address or connection link, as typed.
  final String server;

  /// Certificate fingerprint, empty when not given.
  final String fingerprint;
  final String username;
  final String password;
  final bool register;
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.onSubmit,
    required this.busy,
    this.initialServer = '',
    this.askFingerprint = false,
    this.error,
  });

  final Future<void> Function(LoginRequest request) onSubmit;

  final bool busy;

  /// The server used last time, offered again.
  final String initialServer;

  /// Set when the server turned out to use its own certificate authority:
  /// the fingerprint field is then shown and required.
  final bool askFingerprint;

  final String? error;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _server = TextEditingController(text: widget.initialServer);
  final _fingerprint = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();

  var _register = false;
  var _obscure = true;
  late var _showFingerprint = widget.askFingerprint;

  @override
  void didUpdateWidget(LoginScreen old) {
    super.didUpdateWidget(old);
    if (widget.askFingerprint && !old.askFingerprint) {
      setState(() => _showFingerprint = true);
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _fingerprint.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    widget.onSubmit(LoginRequest(
      server: _server.text.trim(),
      fingerprint: _showFingerprint ? _fingerprint.text.trim() : '',
      username: _username.text.trim(),
      password: _password.text,
      register: _register,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
            child: ConstrainedBox(
              // Full-width fields on a desktop monitor look broken; cap the
              // form at a comfortable reading width.
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: BrandMark(size: 52),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      l10n.appTitle,
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.8,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.loginTagline,
                      style: TextStyle(color: pond.inkMuted, fontSize: 15),
                    ),
                    const SizedBox(height: 28),
                    ..._fields(context),
                    if (widget.error != null) ...[
                      const SizedBox(height: 14),
                      _ErrorCard(message: widget.error!),
                    ],
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: widget.busy ? null : _submit,
                      child: widget.busy
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: pond.onAccent,
                              ),
                            )
                          : Text(_register ? l10n.createAccount : l10n.signIn),
                    ),
                    const SizedBox(height: 6),
                    TextButton(
                      onPressed: widget.busy
                          ? null
                          : () => setState(() => _register = !_register),
                      child: Text(_register ? l10n.haveAccount : l10n.newAccount),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _fields(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    InputDecoration deco(String label, {String? hint, String? helper, Widget? suffix}) =>
        InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          helperMaxLines: 2,
          suffixIcon: suffix,
        );

    return [
      TextFormField(
        controller: _server,
        autocorrect: false,
        enabled: !widget.busy,
        keyboardType: TextInputType.url,
        decoration: deco(l10n.serverLabel, hint: l10n.serverHint),
        validator: (value) =>
            (value?.trim() ?? '').isEmpty ? l10n.serverRequired : null,
      ),
      if (_showFingerprint) ...[
        const SizedBox(height: 10),
        TextFormField(
          controller: _fingerprint,
          autocorrect: false,
          enabled: !widget.busy,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: deco(
            l10n.fingerprintLabel,
            hint: 'XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX',
            helper: l10n.fingerprintHelper,
          ),
          validator: (value) {
            final hex = (value ?? '').replaceAll(RegExp(r'[\s:\-]'), '');
            if (hex.isEmpty && !widget.askFingerprint) return null;
            if (hex.length < 32) return l10n.fingerprintTooShort;
            return null;
          },
        ),
      ] else
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed:
                widget.busy ? null : () => setState(() => _showFingerprint = true),
            child: Text(l10n.haveFingerprint),
          ),
        ),
      const SizedBox(height: 10),
      TextFormField(
        controller: _username,
        autocorrect: false,
        enabled: !widget.busy,
        decoration: deco(l10n.usernameLabel),
        validator: (value) {
          final text = value?.trim() ?? '';
          if (text.length < 3) return l10n.usernameTooShort;
          if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(text)) {
            return l10n.usernameInvalid;
          }
          return null;
        },
      ),
      const SizedBox(height: 10),
      TextFormField(
        controller: _password,
        obscureText: _obscure,
        enabled: !widget.busy,
        decoration: deco(
          l10n.passwordLabel,
          suffix: IconButton(
            tooltip: _obscure ? l10n.showPassword : l10n.hidePassword,
            icon: Icon(_obscure
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
        onFieldSubmitted: (_) => _submit(),
        validator: (value) {
          // The server enforces 10..72 bytes; mirroring the lower bound here
          // avoids a pointless round trip.
          if ((value?.length ?? 0) < 10) return l10n.passwordTooShort;
          return null;
        },
      ),
    ];
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: pond.dangerSoft,
        borderRadius: BorderRadius.circular(PondRadii.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 20, color: pond.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: pond.danger, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
