import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/utils/format.dart';
import '../../shared/widgets/async_states.dart';
import 'backup_decoder.dart';
import 'offline_providers.dart';
import 'screens/offline_documents_view.dart';
import 'screens/offline_folders_view.dart';
import 'screens/offline_tags_view.dart';

/// Offline backup browser — works with zero server connectivity.
///
/// Hub for the imported `.papra-backup` snapshot: shows a summary card and
/// read-only Documents / Tags / Folders tabs mirroring the online app. Also
/// hosts the import flow (file picker → server key → background decode).
class OfflineHomeScreen extends ConsumerStatefulWidget {
  const OfflineHomeScreen({super.key});

  @override
  ConsumerState<OfflineHomeScreen> createState() => _OfflineHomeScreenState();
}

class _OfflineHomeScreenState extends ConsumerState<OfflineHomeScreen> {
  Future<void> _importFlow() async {
    final snapshot = ref.read(offlineSnapshotProvider).value;
    if (snapshot != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Replace backup?'),
          content: Text(
            'A backup from ${formatDate(snapshot.importedAt)} '
            '(${snapshot.documentCount} documents) is already on this device. '
            'Importing a new file replaces it.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Replace')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    final PlatformFile picked;
    try {
      final result = await FilePicker.pickFile(
        type: FileType.any,
        dialogTitle: 'Choose a Papra backup file',
      );
      if (result == null) return;
      picked = result;
    } catch (_) {
      if (mounted) _showSnack('Could not open the file picker.');
      return;
    }
    final path = picked.path;
    if (path == null) {
      _showSnack('Could not access the selected file.');
      return;
    }
    if (!mounted) return;

    final kek = await _promptForKek();
    if (kek == null || !mounted) return;

    final stage = ValueNotifier<String>('Reading file…');
    unawaited(_showImportProgress(picked.name, stage));
    Object? failure;
    try {
      await ref.read(offlineSnapshotProvider.notifier).importBackup(
            sourcePath: path,
            hexKek: kek,
            onStage: (s) => stage.value = s,
          );
    } on BackupDecodingException catch (e) {
      failure = e;
    } catch (_) {
      failure = const BackupDecodingException('Something went wrong while reading the backup.');
    }
    // Close the progress dialog (barrierDismissible + canPop are false, so
    // this is the only way out) before surfacing the outcome.
    if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    stage.dispose();
    if (!mounted) return;

    if (failure is BackupDecodingException) {
      await _showImportError(failure.message);
    } else {
      _showSnack('Backup imported — everything is available offline.');
    }
  }

  Future<void> _showImportProgress(String fileName, ValueNotifier<String> stage) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: ValueListenableBuilder<String>(
          valueListenable: stage,
          builder: (context, value, _) => AlertDialog(
            title: const Text('Importing backup'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 20),
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 16),
                Center(child: Text(value)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showImportError(String message) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import failed'),
        content: Text(message),
        actions: [
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  /// Asks for the server's BACKUPS_KEK, prefilling the remembered one.
  /// Returns the trimmed key, or null when cancelled/empty.
  Future<String?> _promptForKek() async {
    final remembered = ref.read(offlineKekProvider);
    final controller = TextEditingController(text: remembered ?? '');
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Server encryption key'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Backups are encrypted with your server\'s BACKUPS_KEK. '
                'Paste it once to open backups on this device '
                '(it stays stored securely here):',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: remembered == null,
                autocorrect: false,
                enableSuggestions: false,
                maxLines: 2,
                minLines: 1,
                decoration: const InputDecoration(
                  labelText: 'BACKUPS_KEK',
                  hintText: '64-character hex string',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              Navigator.of(dialogContext).pop(value.isEmpty ? null : value);
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    ).then((value) async {
      if (value != null && value.isNotEmpty) {
        await ref.read(offlineKekProvider.notifier).save(value);
      }
      return value;
    });
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete offline backup?'),
        content: const Text(
          'The imported backup and all its files will be removed from this device.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(offlineSnapshotProvider.notifier).deleteSnapshot();
    _showSnack('Offline backup deleted.');
  }

  void _forgetKek() {
    ref.read(offlineKekProvider.notifier).forget();
    _showSnack('Stored server key forgotten.');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final snapshotAsync = ref.watch(offlineSnapshotProvider);
    final snapshot = snapshotAsync.value;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Offline backup'),
          actions: [
            if (snapshot != null)
              PopupMenuButton<String>(
                onSelected: (action) {
                  switch (action) {
                    case 'import':
                      _importFlow();
                    case 'delete':
                      _confirmDelete();
                    case 'forget-kek':
                      _forgetKek();
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'import', child: Text('Replace backup file…')),
                  PopupMenuItem(value: 'delete', child: Text('Delete offline backup')),
                  PopupMenuItem(value: 'forget-kek', child: Text('Forget stored server key')),
                ],
              )
            else
              IconButton(
                tooltip: 'Import backup',
                onPressed: _importFlow,
                icon: const Icon(Icons.backup_outlined),
              ),
          ],
          bottom: snapshot != null
              ? const TabBar(
                  tabs: [
                    Tab(icon: Icon(Icons.description_outlined), text: 'Documents'),
                    Tab(icon: Icon(Icons.sell_outlined), text: 'Tags'),
                    Tab(icon: Icon(Icons.folder_outlined), text: 'Folders'),
                  ],
                )
              : null,
        ),
        body: snapshotAsync.when(
          loading: () => const LoadingState(label: 'Loading offline backup…'),
          error: (error, _) => ErrorState(
            message: 'Could not load the offline backup.',
            onRetry: () => ref.read(offlineSnapshotProvider.notifier).reload(),
          ),
          data: (snapshot) => snapshot == null
              ? _EmptyView(onImport: _importFlow)
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              CircleAvatar(
                                backgroundColor: scheme.primaryContainer,
                                child: Icon(Icons.offline_pin, color: scheme.onPrimaryContainer),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      snapshot.fileName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '${snapshot.documentCount} documents · '
                                      'imported ${formatDate(snapshot.importedAt)}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(color: scheme.onSurfaceVariant),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          OfflineDocumentsView(documents: snapshot.manifest.documents),
                          OfflineTagsView(documents: snapshot.manifest.documents),
                          OfflineFoldersView(documents: snapshot.manifest.documents),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
        floatingActionButton: snapshotAsync.value == null
            ? FloatingActionButton.extended(
                onPressed: _importFlow,
                icon: const Icon(Icons.backup_outlined),
                label: const Text('Import backup'),
              )
            : null,
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            Text('No offline backup yet', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Import a .papra-backup file to browse every document '
              'without signing in or being online.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.backup_outlined),
              label: const Text('Import backup file'),
            ),
          ],
        ),
      ),
    );
  }
}
