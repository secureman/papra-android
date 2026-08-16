import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/settings_store.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/providers.dart';
import '../auth/auth_controller.dart';
import '../auth/auth_state.dart';

/// Settings tab: appearance (theme mode), account info, advanced connection
/// headers (Origin/Referer), and sign out.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _originController = TextEditingController();
  final _refererController = TextEditingController();
  Timer? _headersDebounce;

  @override
  void initState() {
    super.initState();
    _loadHeaderFields();
  }

  @override
  void dispose() {
    _headersDebounce?.cancel();
    _originController.dispose();
    _refererController.dispose();
    super.dispose();
  }

  Future<void> _loadHeaderFields() async {
    final settings = await ref.read(settingsStoreProvider).load();
    if (!mounted) return;
    setState(() {
      _originController.text = settings.originHeader ?? '';
      _refererController.text = settings.refererHeader ?? '';
    });
  }

  /// Persists header fields shortly after they stop changing.
  void _scheduleSaveHeaders() {
    _headersDebounce?.cancel();
    _headersDebounce = Timer(const Duration(milliseconds: 600), () async {
      final store = ref.read(settingsStoreProvider);
      final current = await store.load();
      await store.save(
        originHeader: _originController.text.trim(),
        refererHeader: _refererController.text.trim(),
        serverUrl: current.serverUrl,
        themeMode: current.themeMode,
        rememberMe: current.rememberMe,
        lastOrgId: current.lastOrgId,
        lastOrgName: current.lastOrgName,
        userEmail: current.userEmail,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final auth = ref.watch(authStateProvider);
    final email = auth is AuthAuthenticated ? auth.userEmail : '';
    final baseUrl = auth is AuthAuthenticated ? auth.baseUrl : '';
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _sectionHeader('Appearance'),
          Card(
            margin: EdgeInsets.zero,
            child: RadioGroup<AppThemeMode>(
              groupValue: themeMode,
              onChanged: (mode) {
                if (mode != null) ref.read(themeModeProvider.notifier).setMode(mode);
              },
              child: const Column(
                children: [
                  RadioListTile<AppThemeMode>(
                    title: Text('System default'),
                    subtitle: Text('Follow the device setting'),
                    value: AppThemeMode.system,
                  ),
                  RadioListTile<AppThemeMode>(
                    title: Text('Light'),
                    value: AppThemeMode.light,
                  ),
                  RadioListTile<AppThemeMode>(
                    title: Text('Dark'),
                    value: AppThemeMode.dark,
                  ),
                ],
              ),
            ),
          ),
          _sectionHeader('Account'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  dense: true,
                  leading: Icon(Icons.mail_outline, color: scheme.onSurfaceVariant),
                  title: const Text('Email'),
                  subtitle: Text(email.isEmpty ? '—' : email),
                ),
                const Divider(height: 1),
                ListTile(
                  dense: true,
                  leading: Icon(Icons.dns_outlined, color: scheme.onSurfaceVariant),
                  title: const Text('Server'),
                  subtitle: Text(baseUrl.isEmpty ? '—' : baseUrl),
                ),
              ],
            ),
          ),
          _sectionHeader('Connection (advanced)'),
          Text(
            'Some self-hosted setups only accept requests from a matching '
            'origin. Leave these empty unless your server rejects requests.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                children: [
                  TextField(
                    controller: _originController,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    onChanged: (_) => _scheduleSaveHeaders(),
                    decoration: const InputDecoration(
                      labelText: 'Origin header',
                      hintText: 'https://docs.example.com',
                      prefixIcon: Icon(Icons.open_in_browser),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _refererController,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    onChanged: (_) => _scheduleSaveHeaders(),
                    decoration: const InputDecoration(
                      labelText: 'Referer header',
                      hintText: 'https://docs.example.com/',
                      prefixIcon: Icon(Icons.arrow_outward),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _sectionHeader('About'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  dense: true,
                  leading: Icon(Icons.info_outline, color: scheme.onSurfaceVariant),
                  title: const Text('Papra'),
                  subtitle: const Text('Version 1.0.0'),
                ),
                const Divider(height: 1),
                ListTile(
                  dense: true,
                  leading: Icon(Icons.logout, color: scheme.error),
                  title: Text('Sign out', style: TextStyle(color: scheme.error)),
                  onTap: () => ref.read(authStateProvider.notifier).logout(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      );
}
