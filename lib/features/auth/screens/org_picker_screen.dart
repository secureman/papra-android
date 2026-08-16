import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/models.dart';
import '../../../shared/widgets/async_states.dart';
import '../auth_controller.dart';
import '../auth_state.dart';

class OrgPickerScreen extends ConsumerStatefulWidget {
  const OrgPickerScreen({super.key});

  @override
  ConsumerState<OrgPickerScreen> createState() => _OrgPickerScreenState();
}

class _OrgPickerScreenState extends ConsumerState<OrgPickerScreen> {
  String? _selectingOrgId;

  Future<void> _select(PapraOrganization org) async {
    if (_selectingOrgId != null) return;
    setState(() => _selectingOrgId = org.id);
    try {
      await ref.read(authStateProvider.notifier).selectOrganization(org);
      // Router redirects to home on state change.
    } on PapraApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
        setState(() => _selectingOrgId = null);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not sign in to this organization.')),
        );
        setState(() => _selectingOrgId = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final auth = ref.watch(authStateProvider);

    if (auth is! AuthNeedsOrgSelection) {
      return const LoadingState(label: 'Signing in…');
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Choose an organization')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Signed in as ${auth.userEmail}',
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          for (final org in auth.organizations) ...[
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  foregroundColor: scheme.onPrimaryContainer,
                  child: Text(
                    org.name.isEmpty ? '?' : org.name.characters.first.toUpperCase(),
                  ),
                ),
                title: Text(org.name),
                trailing: _selectingOrgId == org.id
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right),
                onTap: () => _select(org),
              ),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => ref.read(authStateProvider.notifier).logout(),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}
