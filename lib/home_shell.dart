import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/network/api_exception.dart';
import 'core/network/models.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/auth_state.dart';
import 'shared/widgets/papra_logo_mark.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  bool _switchingOrg = false;

  void _goBranch(int index) {
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  Future<void> _openOrgSwitcher() async {
    final controller = ref.read(authStateProvider.notifier);
    final List<PapraOrganization> orgs;
    try {
      orgs = await controller.listOrganizations();
    } on PapraApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
    if (!mounted) return;
    final auth = ref.read(authStateProvider);
    final currentOrgId = auth is AuthAuthenticated ? auth.organizationId : null;

    final selected = await showModalBottomSheet<PapraOrganization>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Switch organization', style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final org in orgs)
              ListTile(
                leading: Icon(
                  org.id == currentOrgId ? Icons.radio_button_checked : Icons.radio_button_off,
                ),
                title: Text(org.name),
                trailing: org.id == currentOrgId ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(org),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;

    setState(() => _switchingOrg = true);
    try {
      await controller.switchOrganization(selected);
    } on PapraApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _switchingOrg = false);
    }
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will need to sign in again to access your documents.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Sign out')),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(authStateProvider.notifier).logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authStateProvider);
    final orgName = auth is AuthAuthenticated ? auth.organizationName : '';

    return Scaffold(
      appBar: AppBar(
        title: Text(orgName.isEmpty ? 'Papra' : orgName),
        actions: [
          IconButton(
            tooltip: 'Switch organization',
            onPressed: _switchingOrg ? null : _openOrgSwitcher,
            icon: _switchingOrg
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.swap_horiz),
          ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: Row(
                  children: [
                    // Brand mark: rounded square soaked in the primary color
                    // (lime in dark mode, coral in light) with the white
                    // Papra document glyph.
                    const PapraLogoMark(size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Papra',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          if (auth is AuthAuthenticated &&
                              auth.userEmail.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              auth.userEmail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('Shares'),
                onTap: () {
                  Navigator.of(context).pop();
                  context.push('/shares');
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Trash'),
                onTap: () {
                  Navigator.of(context).pop();
                  context.push('/trash');
                },
              ),
              ListTile(
                leading: const Icon(Icons.rule),
                title: const Text('Tagging rules'),
                onTap: () {
                  Navigator.of(context).pop();
                  context.push('/tagging-rules');
                },
              ),
              ListTile(
                leading: const Icon(Icons.mail_outline),
                title: const Text('Intake emails'),
                onTap: () {
                  Navigator.of(context).pop();
                  context.push('/intake-emails');
                },
              ),
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: const Text('Backups'),
                onTap: () {
                  Navigator.of(context).pop();
                  context.push('/backups');
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Sign out'),
                onTap: _confirmSignOut,
              ),
            ],
          ),
        ),
      ),
      body: widget.navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: widget.navigationShell.currentIndex,
        onDestinationSelected: _goBranch,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.description_outlined), selectedIcon: Icon(Icons.description), label: 'Documents'),
          NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: 'Folders'),
          NavigationDestination(icon: Icon(Icons.sell_outlined), selectedIcon: Icon(Icons.sell), label: 'Tags'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}
