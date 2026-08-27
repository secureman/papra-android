import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/models.dart';
import '../../shared/utils/format.dart';
import '../../shared/widgets/async_states.dart';
import '../auth/auth_controller.dart';
import '../documents/open_document.dart' show deleteFileIfExists, safeFileName;
import 'backups_ui.dart';

/// Backups hub: destinations list (schedule + next run), add destination,
/// and entry into per-destination run history / restore.
class BackupsScreen extends ConsumerStatefulWidget {
  const BackupsScreen({super.key});

  @override
  ConsumerState<BackupsScreen> createState() => _BackupsScreenState();
}

class _BackupsScreenState extends ConsumerState<BackupsScreen> {
  List<PapraBackupDestination> _destinations = const [];
  BackupsStatusResponse? _status;
  bool _loading = true;
  String? _error;
  bool _exporting = false;
  bool _recovering = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
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
      final results = await Future.wait([
        client.listBackupDestinations(),
        client.getBackupsStatus(),
      ]);
      if (!mounted) return;
      setState(() {
        _destinations = results[0] as List<PapraBackupDestination>;
        _status = results[1] as BackupsStatusResponse;
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

  /// One-off manual export of the whole organization straight to the device —
  /// no destination, nothing persisted, not tracked in run history.
  Future<void> _downloadBackupCopy() async {
    final client = ref.read(apiClientProvider);
    if (client == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      final dir = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose where to save the backup',
      );
      if (dir == null || dir.isEmpty) return;

      final fileName = safeFileName(
        'papra-backup-${DateTime.now().toIso8601String().replaceAll(':', '-')}.papra-backup',
      );
      final target = '$dir/$fileName';
      final partPath = '$target.part';
      try {
        await client.downloadBackupCopy(savePath: partPath);
        await File(partPath).rename(target);
        _showSnack('Backup downloaded.');
      } on PapraApiException catch (e) {
        await deleteFileIfExists(partPath);
        _showSnack(e.message);
      } on FileSystemException {
        await deleteFileIfExists(partPath);
        _showSnack('Could not write to the selected folder.');
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Disaster recovery with no destination at all: pick an existing
  /// `.papra-backup` file and upload it; documents are re-imported in the
  /// background (poll via the restore job screen).
  Future<void> _recoverFromFile() async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore from a backup file?'),
        content: const Text(
          'Documents will be re-imported from the selected .papra-backup file. '
          'Documents that already exist are skipped or untrashed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Choose file'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final picked = await FilePicker.pickFile(type: FileType.any);
    final path = picked?.path;
    if (path == null || !mounted) return;

    setState(() => _recovering = true);
    try {
      final jobId = await client.restoreBackupFromFile(
        filePath: path,
        fileName: picked!.name,
      );
      if (jobId.isEmpty) throw const PapraApiException(message: 'Server did not return a job id.');
      if (mounted) await context.push('/backups/restore/$jobId');
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    } catch (_) {
      _showSnack('Could not upload the backup file.');
    } finally {
      if (mounted) setState(() => _recovering = false);
    }
  }

  Future<void> _addDestination() async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    final drivers = _status?.drivers ?? const <PapraBackupDriver>[];

    final driver = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Add backup destination',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final d in drivers)
              ListTile(
                enabled: d.isConfigured,
                leading: Icon(driverInfo(d.name).icon),
                title: Text(driverInfo(d.name).label),
                subtitle: d.isConfigured ? null : const Text('Not configured on the server'),
                onTap: () => Navigator.of(context).pop(d.name),
              ),
            if (drivers.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No backup drivers are available on this server.'),
              ),
          ],
        ),
      ),
    );
    if (driver == null || !mounted) return;

    final created = await _showAddDestinationForm(driver);
    if (created == true) _load();
  }

  /// Per-driver credential/settings form. Returns true when a destination
  /// was successfully created.
  Future<bool?> _showAddDestinationForm(String driver) async {
    final info = driverInfo(driver);
    final displayNameController = TextEditingController();
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    final pathController = TextEditingController();
    final baseUrlController = TextEditingController();
    final hostController = TextEditingController();
    final remotePathController = TextEditingController();
    var secure = true;
    var testing = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final isGoogleDrive = driver == 'google_drive';
          final isLocal = driver == 'local';
          final isFtp = driver == 'ftp';
          final isWebdav = driver == 'webdav';

          Widget textField(TextEditingController controller, String label,
              {bool obscure = false, bool enabled = true}) {
            return TextField(
              controller: controller,
              enabled: enabled,
              obscureText: obscure,
              decoration: InputDecoration(labelText: label),
            );
          }

          return AlertDialog(
            title: Text('Add ${info.label} destination'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isGoogleDrive)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Google Drive connects through the web (OAuth). '
                        'Add the destination from the server web app, then it will '
                        'appear here.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  else ...[
                    textField(displayNameController, 'Display name'),
                    const SizedBox(height: 12),
                    if (isWebdav) ...[
                      textField(baseUrlController, 'Server URL (https://…)'),
                      const SizedBox(height: 12),
                      textField(remotePathController, 'Remote path (optional)'),
                      const SizedBox(height: 12),
                    ],
                    if (isFtp) ...[
                      textField(hostController, 'Host'),
                      const SizedBox(height: 12),
                      textField(remotePathController, 'Remote path (optional)'),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Secure (FTPS)'),
                        value: secure,
                        onChanged: (v) => setDialogState(() => secure = v),
                      ),
                    ],
                    if (isLocal) ...[
                      textField(pathController, 'Folder path on the server'),
                      const SizedBox(height: 12),
                    ],
                    if (!isLocal) ...[
                      textField(usernameController, 'Username'),
                      const SizedBox(height: 12),
                      textField(passwordController, 'Password', obscure: true),
                    ],
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              if (!isGoogleDrive)
                TextButton(
                  onPressed: testing
                      ? null
                      : () async {
                          final client = ref.read(apiClientProvider);
                          if (client == null) return;
                          setDialogState(() => testing = true);
                          try {
                            final (credentials, settings) = _buildDriverFields(
                              driver: driver,
                              username: usernameController.text.trim(),
                              password: passwordController.text,
                              path: pathController.text.trim(),
                              baseUrl: baseUrlController.text.trim(),
                              host: hostController.text.trim(),
                              remotePath: remotePathController.text.trim(),
                              secure: secure,
                            );
                            final result = await client.testBackupConnection(
                              driver: driver,
                              credentials: credentials,
                              settings: settings,
                            );
                            if (!dialogContext.mounted) return;
                            ScaffoldMessenger.of(dialogContext).showSnackBar(
                              SnackBar(
                                content: Text(
                                  result['accountLabel'] is String &&
                                          (result['accountLabel'] as String).isNotEmpty
                                      ? 'Connection OK — ${result['accountLabel']}'
                                      : 'Connection OK',
                                ),
                              ),
                            );
                          } on PapraApiException catch (e) {
                            if (dialogContext.mounted) {
                              ScaffoldMessenger.of(dialogContext)
                                  .showSnackBar(SnackBar(content: Text(e.message)));
                            }
                          } finally {
                            if (dialogContext.mounted) setDialogState(() => testing = false);
                          }
                        },
                  child: testing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Test connection'),
                ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Add'),
              ),
            ],
          );
        },
      ),
    );
    if (result != true || !mounted) return false;

    final client = ref.read(apiClientProvider);
    if (client == null) return false;
    if (isGoogleDrive(driver)) {
      _showSnack('Google Drive destinations are added through the web app.');
      return false;
    }
    final name = displayNameController.text.trim();
    if (name.isEmpty) {
      _showSnack('Please enter a display name.');
      return false;
    }
    final (credentials, settings) = _buildDriverFields(
      driver: driver,
      username: usernameController.text.trim(),
      password: passwordController.text,
      path: pathController.text.trim(),
      baseUrl: baseUrlController.text.trim(),
      host: hostController.text.trim(),
      remotePath: remotePathController.text.trim(),
      secure: secure,
    );
    try {
      final id = await client.createBackupDestination(
        driver: driver,
        displayName: name,
        credentials: credentials,
        settings: settings,
      );
      if (id.isEmpty) throw const PapraApiException(message: 'Server did not return a destination id.');
      _showSnack('Destination added.');
      return true;
    } on PapraApiException catch (e) {
      _showSnack(e.message);
      return false;
    }
  }

  static bool isGoogleDrive(String driver) => driver == 'google_drive';

  (Map<String, String>, Map<String, dynamic>) _buildDriverFields({
    required String driver,
    required String username,
    required String password,
    required String path,
    required String baseUrl,
    required String host,
    required String remotePath,
    required bool secure,
  }) {
    final credentials = <String, String>{};
    final settings = <String, dynamic>{};
    switch (driver) {
      case 'webdav':
        settings['baseUrl'] = baseUrl;
        settings['remotePath'] = remotePath.isEmpty ? null : remotePath;
        credentials['username'] = username;
        credentials['password'] = password;
      case 'ftp':
        settings['host'] = host;
        settings['remotePath'] = remotePath.isEmpty ? null : remotePath;
        settings['secure'] = secure;
        credentials['username'] = username;
        credentials['password'] = password;
      case 'local':
        settings['path'] = path;
    }
    return (credentials, settings);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Backups')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addDestination,
        icon: const Icon(Icons.add),
        label: const Text('Add destination'),
      ),
      body: _loading
          ? const LoadingState(label: 'Loading backups…')
          : _error != null
              ? ErrorState(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (_status?.isConfigured == true) ...[
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _exporting ? null : _downloadBackupCopy,
                                icon: _exporting
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.download_outlined),
                                label: const Text('Download a copy'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _recovering ? null : _recoverFromFile,
                                icon: _recovering
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.settings_backup_restore),
                                label: const Text('Recover from file'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_status?.isConfigured == false) ...[
                        Card(
                          margin: EdgeInsets.zero,
                          color: scheme.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Icon(Icons.warning_amber, color: scheme.onErrorContainer),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Backups are disabled on this server '
                                    '(BACKUPS_KEK is not set).',
                                    style: TextStyle(color: scheme.onErrorContainer),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_destinations.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 48),
                          child: Column(
                            children: [
                              Icon(Icons.cloud_outlined,
                                  size: 48, color: scheme.onSurfaceVariant),
                              const SizedBox(height: 12),
                              Text(
                                'No backup destinations yet.',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Add one to start backing up your documents.',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        )
                      else
                        for (final d in _destinations) _buildDestinationTile(d, scheme),
                    ],
                  ),
                ),
    );
  }

  Widget _buildDestinationTile(PapraBackupDestination d, ColorScheme scheme) {
    final info = driverInfo(d.driver);
    final lastRun = d.lastRunAt != null && d.lastRunAt!.isNotEmpty ? d.lastRunAt! : null;
    final nextRun = d.nextScheduledAt != null && d.nextScheduledAt!.isNotEmpty
        ? d.nextScheduledAt!
        : null;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        onTap: () async {
          final changed = await context.push<bool>('/backups/destination', extra: d);
          if (changed == true) _load();
        },
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(info.icon, color: scheme.onPrimaryContainer),
        ),
        title: Text(d.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(formatSchedule(d.schedule)),
            if (lastRun != null) Text('Last run: ${formatDate(lastRun)}'),
            if (nextRun != null) Text('Next run: ${formatDate(nextRun)}'),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}
