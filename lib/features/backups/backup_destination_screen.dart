import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/models.dart';
import '../../shared/utils/format.dart';
import '../../shared/widgets/async_states.dart';
import '../auth/auth_controller.dart';
import '../documents/open_document.dart' show deleteFileIfExists, safeFileName;
import 'backups_ui.dart';

/// Backup destination detail: info + schedule, run now, run history (with
/// restore/verify/delete), and remote-file disaster recovery.
class BackupDestinationScreen extends ConsumerStatefulWidget {
  const BackupDestinationScreen({super.key, required this.destination});

  final PapraBackupDestination destination;

  @override
  ConsumerState<BackupDestinationScreen> createState() => _BackupDestinationScreenState();
}

class _BackupDestinationScreenState extends ConsumerState<BackupDestinationScreen> {
  late PapraBackupDestination _destination = widget.destination;
  List<PapraBackupRun> _runs = const [];
  bool _loading = true;
  String? _error;
  bool _runningNow = false;
  bool _reconnecting = false;
  Timer? _pollTimer;

  /// Runs whose envelope claim (local delivery) is currently in flight, so a
  /// re-poll doesn't fire a second one-shot download for the same run.
  final Set<String> _claimingRuns = {};

  /// Last claim attempt per run — a failed attempt backs off before the next
  /// poll retries (the poll can race the server registering the envelope).
  final Map<String, DateTime> _lastClaimAttemptAt = {};

  /// Ready runs whose folder picker the user dismissed — never re-prompt on
  /// every poll; they can still save manually from the run list.
  final Set<String> _dismissedRuns = {};

  static const _claimRetryDelay = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      setState(() {
        _loading = false;
        _error = 'You are not signed in.';
      });
      return;
    }
    if (!silent) setState(() => _loading = true);
    try {
      final runs = await client.listBackupRuns(_destination.id);
      if (!mounted) return;
      setState(() {
        _runs = runs;
        _loading = false;
        _error = null;
      });
      _scheduleNextPoll();
      await _maybeClaimLocalRuns();
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

  /// While a run is still in flight (or a local envelope waits to be claimed),
  /// keep refreshing so the progress bars move and the claim happens promptly.
  void _scheduleNextPoll() {
    _pollTimer?.cancel();
    final hasPendingWork = _runs.any(
      (run) => run.isInProgress || run.status == 'ready_for_download',
    );
    if (!hasPendingWork) return;
    _pollTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) _load(silent: true);
    });
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _runNow() async {
    final client = ref.read(apiClientProvider);
    if (client == null || _runningNow) return;
    setState(() => _runningNow = true);
    try {
      final runId = await client.runBackup(_destination.id);
      if (runId.isEmpty) throw const PapraApiException(message: 'Server did not return a run id.');
      _showSnack('Backup started.');
      _load(silent: true);
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    } finally {
      if (mounted) setState(() => _runningNow = false);
    }
  }

  /// Re-issues the Google Drive authorization (the stored refresh token dies
  /// after Google revokes it — e.g. testing-mode OAuth apps expire tokens after
  /// 7 days). Opens the OAuth consent URL in the browser; the destination's
  /// run history and remote files stay intact once the handshake completes.
  Future<void> _reconnect() async {
    final client = ref.read(apiClientProvider);
    if (client == null || _reconnecting) return;
    setState(() => _reconnecting = true);
    try {
      final url =
          await client.getGoogleDriveConnectUrl(displayName: _destination.displayName);
      if (url.isEmpty) {
        throw const PapraApiException(
          message: 'Server did not return an authorization URL.',
        );
      }
      final opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!opened) _showSnack('Could not open the browser.');
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    } catch (_) {
      _showSnack('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _reconnecting = false);
    }
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _destination.displayName);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename destination'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Display name'),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == _destination.displayName) return;
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      await client.renameBackupDestination(_destination.id, newName);
      setState(() => _destination = _copyWith(_destination, displayName: newName));
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _editSchedule() async {
    final schedule = _destination.schedule;
    var enabled = schedule.isEnabled;
    var days = [...schedule.days];
    var hour = schedule.hour ?? 0;
    var minute = schedule.minute ?? 0;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Backup schedule'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enabled'),
                  value: enabled,
                  onChanged: (v) => setDialogState(() => enabled = v),
                ),
                Text('Days', style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var i = 0; i < 7; i++)
                      FilterChip(
                        label: Text(_dayAbbreviation(i)),
                        selected: days.contains(i),
                        onSelected: (selected) => setDialogState(() {
                          if (selected) {
                            days.add(i);
                          } else {
                            days.remove(i);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: hour,
                        decoration: const InputDecoration(labelText: 'Hour'),
                        items: [
                          for (var h = 0; h < 24; h++)
                            DropdownMenuItem(value: h, child: Text(h.toString().padLeft(2, '0'))),
                        ],
                        onChanged: (v) => setDialogState(() => hour = v ?? 0),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: minute,
                        decoration: const InputDecoration(labelText: 'Minute'),
                        items: [
                          for (var m = 0; m < 60; m++)
                            DropdownMenuItem(value: m, child: Text(m.toString().padLeft(2, '0'))),
                        ],
                        onChanged: (v) => setDialogState(() => minute = v ?? 0),
                      ),
                    ),
                  ],
                ),
              ],
            ),
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
      ),
    );
    if (saved != true) return;

    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      final newSchedule = PapraBackupSchedule(
        isEnabled: enabled,
        days: days,
        hour: enabled ? hour : null,
        minute: enabled ? minute : null,
      );
      final nextScheduledAt = await client.updateBackupSchedule(_destination.id, newSchedule);
      setState(() {
        _destination = _copyWith(
          _destination,
          schedule: newSchedule,
          nextScheduledAt: nextScheduledAt,
        );
      });
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete destination?'),
        content: Text('“${_destination.displayName}” and its run history will be removed. '
            'Backup files already on the destination are left in place.'),
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
      await client.deleteBackupDestination(_destination.id);
      if (mounted) Navigator.of(context).pop(true);
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  // ── Runs ──────────────────────────────────────────────────────────────────

  /// Local-folder destinations hold the finished envelope in memory for ~10
  /// minutes with a one-shot download endpoint (see the server's
  /// backups.local-delivery.service). As soon as a run reaches
  /// `ready_for_download`, open the folder picker and stream it to the device.
  Future<void> _maybeClaimLocalRuns() async {
    if (_destination.driver != 'local') return;
    for (final run in _runs) {
      if (run.status != 'ready_for_download') continue;
      if (_claimingRuns.contains(run.id) || _dismissedRuns.contains(run.id)) continue;
      final lastAttempt = _lastClaimAttemptAt[run.id];
      if (lastAttempt != null && DateTime.now().difference(lastAttempt) < _claimRetryDelay) {
        continue;
      }
      _lastClaimAttemptAt[run.id] = DateTime.now();
      _claimingRuns.add(run.id);
      try {
        await _claimLocalRun(run);
      } finally {
        _claimingRuns.remove(run.id);
      }
    }
  }

  Future<void> _claimLocalRun(PapraBackupRun run) async {
    final client = ref.read(apiClientProvider);
    if (client == null || !mounted) return;

    final fileName =
        safeFileName(run.remoteFileName ?? 'papra-backup-${DateTime.now().toIso8601String()}.papra-backup');

    final String? dir;
    try {
      dir = await FilePicker.getDirectoryPath(
        dialogTitle: 'Backup ready — choose where to save “$fileName”',
      );
    } catch (_) {
      // Picker unavailable/failed — stop auto-prompting; manual Save still works.
      if (!mounted) return;
      setState(() => _dismissedRuns.add(run.id));
      return;
    }
    if (!mounted) return;
    if (dir == null || dir.isEmpty) {
      setState(() => _dismissedRuns.add(run.id));
      _showSnack('Backup ready — tap “Save” on the run to pick a folder before it expires.');
      return;
    }

    final target = '$dir/$fileName';
    final partPath = '$target.part';
    try {
      await client.downloadReadyBackupRun(
        destinationId: _destination.id,
        runId: run.id,
        savePath: partPath,
      );
      await File(partPath).rename(target);
      _showSnack('Backup saved.');
      await _load(silent: true);
    } on PapraApiException catch (e) {
      await deleteFileIfExists(partPath);
      // dio wraps save-path write failures in a DioException whose `error` is
      // the underlying FileSystemException (scoped storage) — don't retry
      // those, the folder simply isn't writable from Dart.
      final cause = e.cause;
      final underlying = cause is DioException ? cause.error : cause;
      if (underlying is IOException) {
        _showSnack('Could not write to the selected folder.');
        if (!mounted) return;
        setState(() => _dismissedRuns.add(run.id));
        return;
      }
      _showSnack('Could not save the backup file.');
      // The claim may have raced the server registering the envelope — leave
      // the run unclaimed so the next poll retries after the backoff.
      _scheduleNextPoll();
    } on FileSystemException {
      await deleteFileIfExists(partPath);
      _showSnack('Could not write to the selected folder.');
      if (!mounted) return;
      setState(() => _dismissedRuns.add(run.id));
    } catch (_) {
      await deleteFileIfExists(partPath);
      _showSnack('Could not save the backup file.');
      _scheduleNextPoll();
    }
  }

  /// Manual entry point for a ready local run (e.g. after dismissing the
  /// automatic picker).
  Future<void> _saveReadyRun(PapraBackupRun run) async {
    if (_claimingRuns.contains(run.id)) return;
    _dismissedRuns.remove(run.id);
    _lastClaimAttemptAt.remove(run.id);
    _claimingRuns.add(run.id);
    try {
      await _claimLocalRun(run);
    } finally {
      _claimingRuns.remove(run.id);
    }
  }

  Future<void> _restoreRun(PapraBackupRun run) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore from this backup?'),
        content: Text(
          '“${run.remoteFileName ?? run.id}” will be downloaded and its documents '
          'restored into your organization. This runs in the background.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      final jobId = await client.restoreBackupRun(_destination.id, run.id);
      if (jobId.isEmpty) throw const PapraApiException(message: 'Server did not return a job id.');
      if (mounted) {
        await context.push('/backups/restore/$jobId');
      }
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _verifyRun(PapraBackupRun run) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      final result = await client.verifyBackupRun(_destination.id, run.id);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(result.valid ? 'Backup verified' : 'Verification failed'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _verifyRow('Documents checked', result.totalDocuments),
              _verifyRow('Valid', result.validDocuments),
              _verifyRow('Invalid', result.invalidDocuments),
              if (result.errors.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  result.errors.join('\n'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _deleteRun(PapraBackupRun run) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this backup record?'),
        content: const Text('The local run record is removed. The file on the '
            'destination is left in place.'),
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
      await client.deleteBackupRun(_destination.id, run.id);
      _load();
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  // ── Remote files (disaster recovery) ──────────────────────────────────────

  Future<void> _browseRemoteFiles() async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    List<PapraBackupRemoteFile> files;
    try {
      files = await client.listRemoteBackupFiles(_destination.id);
    } on PapraApiException catch (e) {
      _showSnack(e.message);
      return;
    }
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: files.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(32),
                child: Text('No backup files found on this destination.'),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text('Backups on ${_destination.displayName}',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  for (final file in files)
                    ListTile(
                      leading: const Icon(Icons.backup_outlined),
                      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text([
                        if (file.size != null) formatBytes(file.size!),
                        if (file.modifiedAt != null && file.modifiedAt!.isNotEmpty)
                          formatDate(file.modifiedAt!),
                      ].join(' · ')),
                      trailing: TextButton(
                        onPressed: () => _restoreRemoteFile(file),
                        child: const Text('Restore'),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Future<void> _restoreRemoteFile(PapraBackupRemoteFile file) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore from remote backup?'),
        content: Text('“${file.name}” will be downloaded and its documents restored.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final jobId = await client.restoreBackupFromRemoteFile(_destination.id, file.remoteFileId);
      if (jobId.isEmpty) throw const PapraApiException(message: 'Server did not return a job id.');
      if (mounted) {
        await context.push('/backups/restore/$jobId');
      }
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final info = driverInfo(_destination.driver);
    final d = _destination;

    return Scaffold(
      appBar: AppBar(title: Text(d.displayName, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _loading
          ? const LoadingState(label: 'Loading runs…')
          : _error != null
              ? ErrorState(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    children: [
                      Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: scheme.primaryContainer,
                                    child: Icon(info.icon, color: scheme.onPrimaryContainer),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(info.label,
                                            style: Theme.of(context).textTheme.titleSmall),
                                        if (d.accountLabel != null && d.accountLabel!.isNotEmpty)
                                          Text(
                                            d.accountLabel!,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(color: scheme.onSurfaceVariant),
                                          ),
                                      ],
                                    ),
                                  ),
                                  PopupMenuButton<String>(
                                    onSelected: (action) {
                                      switch (action) {
                                        case 'rename':
                                          _rename();
                                        case 'schedule':
                                          _editSchedule();
                                        case 'reconnect':
                                          _reconnect();
                                        case 'delete':
                                          _delete();
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      PopupMenuItem(value: 'rename', child: Text('Rename')),
                                      PopupMenuItem(value: 'schedule', child: Text('Edit schedule')),
                                      if (d.driver == 'google_drive')
                                        PopupMenuItem(
                                          value: 'reconnect',
                                          child: Text(_reconnecting
                                              ? 'Reconnecting…'
                                              : 'Reconnect Google Drive'),
                                        ),
                                      PopupMenuItem(value: 'delete', child: Text('Delete destination')),
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Text(formatSchedule(d.schedule),
                                  style: Theme.of(context).textTheme.bodyMedium),
                              if (d.nextScheduledAt != null && d.nextScheduledAt!.isNotEmpty)
                                Text(
                                  'Next run: ${formatDate(d.nextScheduledAt!)}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: scheme.onSurfaceVariant),
                                ),
                              if (d.lastRunAt != null && d.lastRunAt!.isNotEmpty)
                                Text(
                                  'Last run: ${formatDate(d.lastRunAt!)}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: scheme.onSurfaceVariant),
                                ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: _runningNow ? null : _runNow,
                                      icon: _runningNow
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(strokeWidth: 2),
                                            )
                                          : const Icon(Icons.play_arrow),
                                      label: const Text('Run backup now'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton.icon(
                                    onPressed: _browseRemoteFiles,
                                    icon: const Icon(Icons.cloud_download_outlined),
                                    label: const Text('Remote files'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text('Run history (${_runs.length})',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 4),
                      if (_runs.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'No runs yet. Tap “Run backup now” to create the first one.',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        )
                      else
                        for (final run in _runs) _buildRunTile(run, scheme),
                    ],
                  ),
                ),
    );
  }

  Widget _buildRunTile(PapraBackupRun run, ColorScheme scheme) {
    final canRestore = run.status == 'succeeded' && (run.remoteFileId ?? '').isNotEmpty;
    final failed = run.status == 'failed';
    final inProgress = run.isInProgress;
    final readyToSave = run.status == 'ready_for_download';
    final claiming = _claimingRuns.contains(run.id);
    final progress = inProgress ? describeRunProgress(run) : null;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(
          backupStatusIcon(run.status),
          color: failed
              ? scheme.error
              : run.status == 'succeeded'
                  ? Colors.green
                  : scheme.primary,
        ),
        title: Text(
          '${run.trigger == 'scheduled' ? 'Scheduled' : 'Manual'} backup · ${formatDate(run.createdAt)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (progress != null) ...[
              Text(progress.label),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: progress.percent),
              const SizedBox(height: 6),
            ]
            else
              Text([
                backupStatusLabel(run.status),
                if (run.documentsCount != null && !readyToSave)
                  '${run.documentsCount} documents',
                if (run.totalSizeBytes != null) formatBytes(run.totalSizeBytes!),
              ].join(' · ')),
            if (failed && run.errorMessage != null && run.errorMessage!.isNotEmpty)
              Text(run.errorMessage!, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.error, fontSize: 12)),
            if (failed && run.errorMessage != null && isOAuthAuthFailure(run.errorMessage!)) ...[
              const SizedBox(height: 4),
              Text(
                'Google Drive authorization expired — reconnect to back up again.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _reconnecting ? null : _reconnect,
                  icon: _reconnecting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link, size: 16),
                  label: Text(_reconnecting ? 'Reconnecting…' : 'Reconnect'),
                ),
              ),
            ],
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (action) {
            switch (action) {
              case 'save':
                _saveReadyRun(run);
              case 'restore':
                _restoreRun(run);
              case 'verify':
                _verifyRun(run);
              case 'delete':
                _deleteRun(run);
            }
          },
          itemBuilder: (context) => [
            if (readyToSave && _destination.driver == 'local')
              PopupMenuItem(
                value: 'save',
                enabled: !claiming,
                child: Text(claiming ? 'Saving…' : 'Save to device'),
              ),
            if (canRestore) const PopupMenuItem(value: 'restore', child: Text('Restore')),
            if (run.status == 'succeeded')
              const PopupMenuItem(value: 'verify', child: Text('Verify integrity')),
            if (!inProgress) const PopupMenuItem(value: 'delete', child: Text('Delete record')),
          ],
        ),
      ),
    );
  }

  Widget _verifyRow(String label, int value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text('$value'),
        ],
      ),
    );
  }

  static String _dayAbbreviation(int day) =>
      const ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][day];
}

PapraBackupDestination _copyWith(
  PapraBackupDestination d, {
  String? displayName,
  PapraBackupSchedule? schedule,
  String? nextScheduledAt,
}) {
  return PapraBackupDestination(
    id: d.id,
    driver: d.driver,
    displayName: displayName ?? d.displayName,
    settings: d.settings,
    accountLabel: d.accountLabel,
    isEnabled: d.isEnabled,
    schedule: schedule ?? d.schedule,
    lastRunAt: d.lastRunAt,
    nextScheduledAt: nextScheduledAt ?? d.nextScheduledAt,
    createdAt: d.createdAt,
  );
}
