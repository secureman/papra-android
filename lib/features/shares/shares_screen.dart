import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/models.dart';
import '../../shared/utils/format.dart';
import '../../shared/widgets/async_states.dart';
import '../auth/auth_controller.dart';

/// Shares screen: every share link in the organization.
///
/// Supports creating a link for any document (with optional expiry + password),
/// editing a link's expiry/password, enabling/disabling it, copying its public
/// URL, and deleting it.
class SharesScreen extends ConsumerStatefulWidget {
  const SharesScreen({super.key});

  @override
  ConsumerState<SharesScreen> createState() => _SharesScreenState();
}

class _SharesScreenState extends ConsumerState<SharesScreen> {
  List<PapraShareLink> _links = const [];
  bool _loading = true;
  String? _error;

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
      final links = await client.listOrganizationShareLinks();
      if (!mounted) return;
      setState(() {
        _links = links;
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

  Future<void> _copyLink(PapraShareLink link) async {
    if (link.url.isEmpty) {
      _showSnack('This link has no URL.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: link.url));
    _showSnack('Link copied to clipboard.');
  }

  Future<void> _toggleEnabled(PapraShareLink link) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      await client.updateShareLink(link.id, isEnabled: !link.isEnabled);
      _showSnack(link.isEnabled ? 'Link disabled.' : 'Link enabled.');
      _load();
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _deleteLink(PapraShareLink link) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete share link?'),
        content: Text('The link for “${_linkLabel(link)}” will stop working '
            'immediately. This cannot be undone.'),
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
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      await client.deleteShareLink(link.id);
      _showSnack('Share link deleted.');
      _load();
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _createLink() async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;

    final document = await showDialog<PapraDocument>(
      context: context,
      builder: (context) => const _DocumentPickerDialog(),
    );
    if (document == null || !mounted) return;

    final form = await _showLinkForm(
      title: 'New share link',
      documentName: document.name,
    );
    if (form == null || !mounted) return;

    try {
      await client.createShareLink(
        document.id,
        expiresAt: form.expiresAtIso,
        password: form.password,
      );
      _showSnack('Share link created.');
      _load();
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _editLink(PapraShareLink link) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;

    final form = await _showLinkForm(
      title: 'Edit share link',
      documentName: _linkLabel(link),
      initialExpiresAt: link.expiresAt,
      isPasswordProtected: link.isPasswordProtected,
    );
    if (form == null || !mounted) return;

    try {
      await client.updateShareLink(
        link.id,
        expiresAt: form.expiresAtIso,
        password: form.password,
        clearExpiresAt: form.clearExpiresAt,
        clearPassword: form.clearPassword,
      );
      _showSnack('Share link updated.');
      _load();
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<_LinkFormState?> _showLinkForm({
    required String title,
    required String documentName,
    String? initialExpiresAt,
    bool isPasswordProtected = false,
  }) async {
    final initialExpiry = initialExpiresAt != null
        ? DateTime.tryParse(initialExpiresAt)
        : null;
    final form = _LinkFormState(
      setExpiry: initialExpiry != null,
      expiry: initialExpiry,
    );

    return showDialog<_LinkFormState>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> pickExpiry() async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: context,
              initialDate: form.expiry ?? now,
              firstDate: now.subtract(const Duration(days: 1)),
              lastDate: now.add(const Duration(days: 365 * 10)),
            );
            if (picked != null) {
              setDialogState(() {
                form.expiry = DateTime(picked.year, picked.month, picked.day);
                form.setExpiry = true;
              });
            }
          }

          return AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    documentName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  // Prominent expiry control: a tappable row with a calendar
                  // icon, a dynamic subtitle ("Never expires" vs the date),
                  // and a trailing switch. Both states are clearly visible.
                  Card(
                    margin: EdgeInsets.zero,
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                      leading: const Icon(Icons.event_outlined),
                      title: const Text('Expires'),
                      subtitle: Text(
                        form.setExpiry
                            ? (form.expiry == null
                                ? 'Pick a date…'
                                : 'On ${formatDate(form.expiry!.toIso8601String())}')
                            : 'Never expires',
                      ),
                      trailing: Switch(
                        value: form.setExpiry,
                        onChanged: (v) => setDialogState(() {
                          form.setExpiry = v;
                          if (!v) form.expiry = null;
                        }),
                      ),
                      onTap: () => setDialogState(() {
                        form.setExpiry = !form.setExpiry;
                        if (!form.setExpiry) form.expiry = null;
                      }),
                    ),
                  ),
                  if (form.setExpiry) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: pickExpiry,
                            icon: const Icon(Icons.calendar_today, size: 18),
                            label: Text(
                              form.expiry == null
                                  ? 'Pick a date'
                                  : formatDate(form.expiry!.toIso8601String()),
                            ),
                          ),
                        ),
                        if (form.expiry != null) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: 'Clear date',
                            onPressed: () =>
                                setDialogState(() => form.expiry = null),
                            icon: const Icon(Icons.clear),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: form._passwordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: isPasswordProtected
                          ? 'Password (leave empty to keep current)'
                          : 'Password (optional)',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(form),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
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
      appBar: AppBar(title: const Text('Shares')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createLink,
        icon: const Icon(Icons.add),
        label: const Text('New link'),
      ),
      body: _loading
          ? const LoadingState(label: 'Loading share links…')
          : _error != null
              ? ErrorState(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _links.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 160),
                            EmptyState(
                              icon: Icons.link,
                              title: 'No share links yet',
                              message: 'Create a link to share a document '
                                  'with anyone, with or without a password '
                                  'and expiration date.',
                            ),
                          ],
                        )
                      : ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(16),
                          children: [
                            for (final link in _links) _buildLinkTile(link, scheme),
                          ],
                        ),
                ),
    );
  }

  Widget _buildLinkTile(PapraShareLink link, ColorScheme scheme) {
    final label = _linkLabel(link);

    final meta = <String>[
      if (link.isPasswordProtected) 'Password protected',
      if (link.expiresAt != null && link.expiresAt!.isNotEmpty)
        'Expires ${formatDate(link.expiresAt!)}',
      if (!link.isEnabled) 'Disabled',
      if (link.isDocumentDeleted) 'Document in trash',
    ];

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: link.isEnabled
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          child: Icon(
            Icons.link,
            color: link.isEnabled
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
        title: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: link.isEnabled
              ? null
              : TextStyle(color: scheme.onSurfaceVariant),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              link.url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.primary),
            ),
            if (meta.isNotEmpty)
              Text(
                meta.join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Copy link',
              icon: const Icon(Icons.copy, size: 20),
              onPressed: () => _copyLink(link),
            ),
            PopupMenuButton<String>(
              onSelected: (action) {
                switch (action) {
                  case 'edit':
                    _editLink(link);
                  case 'toggle':
                    _toggleEnabled(link);
                  case 'delete':
                    _deleteLink(link);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(
                  value: 'toggle',
                  child: Text(link.isEnabled ? 'Disable' : 'Enable'),
                ),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _linkLabel(PapraShareLink link) {
    final name = link.documentName;
    if (name != null && name.isNotEmpty) return name;
    return 'Shared document';
  }
}

/// Mutable form state shared between the dialog builder and the parent.
class _LinkFormState {
  _LinkFormState({required this.setExpiry, this.expiry});

  bool setExpiry;
  DateTime? expiry;
  final _passwordController = TextEditingController();
  final _clearPassword = false;

  /// ISO-8601 expiry to send, or null when no expiry should be set. Sent as a
  /// UTC timestamp (`…Z`) — the fork's `v.isoTimestamp()` schema rejects
  /// timestamps without a timezone (e.g. a local `toIso8601String()`).
  String? get expiresAtIso =>
      setExpiry ? expiry?.toUtc().toIso8601String() : null;

  /// The new password, or null when the user did not type one.
  String? get password =>
      _passwordController.text.isEmpty ? null : _passwordController.text;

  /// Whether the API should clear the link's expiry.
  bool get clearExpiresAt => !setExpiry;

  /// Whether the API should clear the link's password.
  bool get clearPassword => _clearPassword;
}

/// Searchable document picker used by the "New link" flow.
class _DocumentPickerDialog extends ConsumerStatefulWidget {
  const _DocumentPickerDialog();

  @override
  ConsumerState<_DocumentPickerDialog> createState() => _DocumentPickerDialogState();
}

class _DocumentPickerDialogState extends ConsumerState<_DocumentPickerDialog> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';
  List<PapraDocument> _documents = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'You are not signed in.';
        });
      }
      return;
    }
    setState(() => _loading = true);
    try {
      final resp = await client.listDocuments(search: _query.trim(), pageSize: 50);
      if (!mounted) return;
      setState(() {
        _documents = resp.documents;
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
        _error = 'Could not load documents.';
      });
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      setState(() => _query = value.trim());
      _search();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('Select a document'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search documents',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(child: _buildResults(scheme)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildResults(ColorScheme scheme) {
    if (_loading) return const LoadingState(label: 'Searching…');
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: _search);
    }
    if (_documents.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: _query.trim().isEmpty ? 'No documents yet' : 'No results',
        message: _query.trim().isEmpty
            ? 'Upload a document before sharing.'
            : 'No documents match “${_query.trim()}”.',
      );
    }
    return ListView.builder(
      itemCount: _documents.length,
      itemBuilder: (context, index) {
        final document = _documents[index];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.description_outlined, size: 20),
          title: Text(document.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(formatBytes(document.size)),
          onTap: () => Navigator.of(context).pop(document),
        );
      },
    );
  }
}
