import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/account.dart';
import '../theme.dart';
import 'slate.dart';
import 'widgets.dart';

/// Settings → Halcyn account: signing in, how syncing is going, and the account's
/// password and recovery key.
class AccountSettings extends StatelessWidget {
  const AccountSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = AppScope.of(context).account;
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) {
        final muted = theme.textTheme.bodyMedium?.copyWith(
          color: Palette.textMuted,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Text('Halcyn account', style: theme.textTheme.titleMedium),
            ),
            if (!account.signedIn) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  'Keeps your linked Tidal and YouTube Music and your playlists '
                  'the same on every device you sign in on. Sign-ins are '
                  'encrypted with your password before they leave this device.',
                  style: muted,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.tonal(
                      onPressed: () => _signIn(context, create: false),
                      child: const Text('Sign in'),
                    ),
                    OutlinedButton(
                      onPressed: () => _signIn(context, create: true),
                      child: const Text('Create account'),
                    ),
                  ],
                ),
              ),
            ] else ...[
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: const Icon(Icons.account_circle_outlined),
                title: Text(account.email ?? ''),
                subtitle: Text(_status(context, account)),
                trailing: account.syncing
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        tooltip: 'Sync now',
                        icon: const Icon(Icons.sync_rounded),
                        onPressed: account.locked ? null : account.sync,
                      ),
              ),
              if (account.recoveryKey case final key?)
                _RecoveryKey(text: key, onSaved: account.forgetRecoveryKey),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (account.locked)
                      FilledButton.tonal(
                        onPressed: () => _unlock(context),
                        child: const Text('Enter password'),
                      )
                    else
                      OutlinedButton(
                        onPressed: () => _changePassword(context),
                        child: const Text('Change password'),
                      ),
                    OutlinedButton(
                      onPressed: () => _run(context, account.signOut),
                      child: const Text('Sign out'),
                    ),
                    TextButton(
                      onPressed: () => _delete(context),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      child: const Text('Delete account…'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  static String _status(BuildContext context, AccountController account) {
    if (account.locked) {
      return 'Enter your password to open the saved sign-ins on this device';
    }
    if (account.syncing) return 'Syncing…';
    if (account.syncError case final error?) return 'Couldn\'t sync: $error';
    final at = account.lastSync;
    if (at == null) return 'Not synced yet';
    final ago = DateTime.now().difference(at);
    return switch (ago.inMinutes) {
      0 => 'Synced just now',
      1 => 'Synced a minute ago',
      < 60 => 'Synced ${ago.inMinutes} minutes ago',
      _ => 'Synced at ${TimeOfDay.fromDateTime(at).format(context)}',
    };
  }

  Future<void> _signIn(BuildContext context, {required bool create}) async {
    final account = AppScope.of(context).account;
    await showDialog<void>(
      context: context,
      builder: (_) => _PasswordDialog(
        title: create ? 'Create a Halcyn account' : 'Sign in to Halcyn',
        action: create ? 'Create account' : 'Sign in',
        email: true,
        confirm: create,
        note: create
            ? 'Use at least $minPasswordLength characters. Halcyn can\'t reset '
                  'it for you, so keep it somewhere safe.'
            : null,
        run: (email, password) => create
            ? account.signUp(email!, password)
            : account.signIn(email!, password),
      ),
    );
  }

  Future<void> _unlock(BuildContext context) async {
    final account = AppScope.of(context).account;
    await showDialog<void>(
      context: context,
      builder: (_) => _PasswordDialog(
        title: 'Enter your password',
        action: 'Open',
        note: 'Your password changed on another device.',
        run: (_, password) => account.unlock(password),
      ),
    );
  }

  Future<void> _changePassword(BuildContext context) async {
    final account = AppScope.of(context).account;
    String? current;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _PasswordDialog(
        title: 'Current password',
        action: 'Next',
        run: (_, password) async => current = password,
      ),
    );
    if (ok != true || current == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _PasswordDialog(
        title: 'New password',
        action: 'Change password',
        confirm: true,
        note: 'Your other devices ask for it once, next time they sync.',
        run: (_, password) => account.changePassword(current!, password),
      ),
    );
  }

  Future<void> _delete(BuildContext context) async {
    final account = AppScope.of(context).account;
    final yes = await confirm(
      context,
      title: 'Delete your Halcyn account?',
      message:
          'This deletes the account and the playlists and sign-ins saved in it. '
          'What\'s on this device stays.',
      action: 'Delete',
    );
    if (yes && context.mounted) await _run(context, account.deleteAccount);
  }

  static Future<void> _run(
    BuildContext context,
    Future<void> Function() step,
  ) async {
    try {
      await step();
    } on Object catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(describeAccountError(e)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

/// Shown once after signing up: the key that opens the saved sign-ins if the password
/// is ever lost.
class _RecoveryKey extends StatelessWidget {
  const _RecoveryKey({required this.text, required this.onSaved});

  final String text;
  final VoidCallback onSaved;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 4, 24, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Palette.surfaceHigh,
        borderRadius: BorderRadius.circular(Palette.r(12)),
        border: Border.all(color: Palette.accent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your recovery key', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            'Write this down. If you ever forget your password, it\'s the only '
            'way to get your saved sign-ins back. It won\'t be shown again.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: Palette.textMuted,
            ),
          ),
          const SizedBox(height: 12),
          SelectableText(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: text)),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy'),
              ),
              FilledButton.tonal(
                onPressed: onSaved,
                child: const Text('I\'ve saved it'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Asks for a password (and an email, and the password again when it's a new one),
/// runs [run] with them, and shows what went wrong without closing. Pops true once
/// [run] succeeds.
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({
    required this.title,
    required this.action,
    required this.run,
    this.email = false,
    this.confirm = false,
    this.note,
  });

  final String title;
  final String action;
  final bool email;
  final bool confirm;
  final String? note;
  final Future<void> Function(String? email, String password) run;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _again = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _again.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (widget.email && !_email.text.contains('@')) {
      return setState(() => _error = 'Enter your email address.');
    }
    if (widget.confirm) {
      if (AccountController.passwordProblem(_password.text)
          case final problem?) {
        return setState(() => _error = problem);
      }
      if (_password.text != _again.text) {
        return setState(() => _error = 'The two passwords are different.');
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.run(widget.email ? _email.text : null, _password.text);
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeAccountError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: AutofillGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.note case final note?) ...[
                Text(
                  note,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Palette.textMuted,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (widget.email)
                TextField(
                  controller: _email,
                  autofocus: true,
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
              TextField(
                controller: _password,
                autofocus: !widget.email,
                enabled: !_busy,
                obscureText: true,
                autofillHints: [
                  widget.confirm
                      ? AutofillHints.newPassword
                      : AutofillHints.password,
                ],
                decoration: const InputDecoration(labelText: 'Password'),
                onSubmitted: widget.confirm ? null : (_) => _submit(),
              ),
              if (widget.confirm)
                TextField(
                  controller: _again,
                  enabled: !_busy,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password again',
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                Text(error, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(widget.action),
        ),
      ],
    );
  }
}
