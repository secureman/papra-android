import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/models.dart';
import '../../shared/utils/format.dart';
import '../../shared/widgets/async_states.dart';
import '../auth/auth_controller.dart';

/// Intake emails screen.
///
/// Lists the organization's email addresses that automatically ingest
/// documents. Supports creating new addresses (generated server-side),
/// enabling/disabling them, restricting which senders may use them, copying
/// the address, and deleting it.
class IntakeEmailsScreen extends ConsumerStatefulWidget {
  const IntakeEmailsScreen({super.key});

  @override
  ConsumerState<IntakeEmailsScreen> createState() => _IntakeEmailsScreenState();
}

class _IntakeEmailsScreenState extends ConsumerState<IntakeEmailsScreen> {
  List<PapraIntakeEmail> _emails = const [];
  bool _loading = true;
  String? _error;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'You are not signed in.';
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final emails = await client.listIntakeEmails();
      if (!mounted) return;
      setState(() {
        _emails = emails;
        _loading = false;
        _error = null;
      });
    } on PapraApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Something went wrong. Please try again.';
      });
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _createEmail() async {
    final client = ref.read(apiClientProvider);
    if (client == null || _creating) return;
    setState(() => _creating = true);
    try {
      await client.createIntakeEmail();
      _showSnack('Intake address created.');
      _load();
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _copyAddress(PapraIntakeEmail email) async {
    await Clipboard.setData(ClipboardData(text: email.emailAddress));
    _showSnack('Address copied to clipboard.');
  }

  Future<void> _toggleEnabled(PapraIntakeEmail email) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      await client.updateIntakeEmail(email.id, isEnabled: !email.enabled);
      _showSnack(email.enabled ? 'Address disabled.' : 'Address enabled.');
      _load();
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _editAllowedOrigins(PapraIntakeEmail email) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;

    final controller = TextEditingController(text: email.allowedOrigins.join('\n'));
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Allowed senders'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              maxLines: 6,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email addresses, one per line',
                helperText: 'Only these senders may use this address. '
                    'Leave empty to accept mail from anyone.',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Sends to ${email.emailAddress}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;

    final origins = controller.text
        .split(RegExp(r'[\n,;]'))
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toList();

    try {
      await client.updateIntakeEmail(email.id, allowedOrigins: origins);
      _showSnack('Allowed senders updated.');
      _load();
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _deleteEmail(PapraIntakeEmail email) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete intake address?'),
        content: Text('${email.emailAddress} will stop accepting new '
            'documents. Already ingested documents are kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await client.deleteIntakeEmail(email.id);
      _showSnack('Intake address deleted.');
      _load();
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Reload whenever the authenticated client changes (org switch, re-login).
    ref.listen(apiClientProvider, (previous, next) {
      if (previous != next) _load();
    });

    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Intake emails')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _creating ? null : _createEmail,
        icon: _creating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: const Text('New address'),
      ),
      body: _loading
          ? const LoadingState(label: 'Loading intake emails…')
          : _error != null
              ? ErrorState(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _emails.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 160),
                            EmptyState(
                              icon: Icons.mail_outline,
                              title: 'No intake emails yet',
                              message: 'Create an address to receive '
                                  'documents by email — anything sent to it '
                                  'is ingested automatically.',
                            ),
                          ],
                        )
                      : ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(16),
                          children: [
                            for (final email in _emails)
                              _buildEmailTile(email, scheme),
                          ],
                        ),
                ),
    );
  }

  Widget _buildEmailTile(PapraIntakeEmail email, ColorScheme scheme) {
    final origins = email.allowedOrigins;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: email.enabled
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          child: Icon(
            Icons.mail_outline,
            color: email.enabled
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
        title: Text(
          email.emailAddress,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: email.enabled
              ? null
              : TextStyle(color: scheme.onSurfaceVariant),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!email.enabled)
              Text('Disabled', style: Theme.of(context).textTheme.bodySmall)
            else
              Text(
                origins.isEmpty
                    ? 'Accepts mail from anyone'
                    : 'Allowed senders: ${origins.join(', ')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (email.createdAt != null && email.createdAt!.isNotEmpty)
              Text(
                'Created ${formatDate(email.createdAt!)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Copy address',
              icon: const Icon(Icons.copy, size: 20),
              onPressed: () => _copyAddress(email),
            ),
            Switch(value: email.enabled, onChanged: (_) => _toggleEnabled(email)),
            PopupMenuButton<String>(
              onSelected: (action) {
                switch (action) {
                  case 'edit':
                    _editAllowedOrigins(email);
                  case 'delete':
                    _deleteEmail(email);
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit allowed senders')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
