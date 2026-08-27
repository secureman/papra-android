import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/models.dart';
import '../../shared/utils/format.dart';
import '../../shared/widgets/async_states.dart';
import '../auth/auth_controller.dart';
import 'backups_ui.dart';

/// Polls a restore job (`backups/restore-jobs/job/:id`) every 2 seconds and
/// renders the phase, byte/document progress and final counts. Stops polling
/// once the job reaches a terminal state.
class RestoreProgressScreen extends ConsumerStatefulWidget {
  const RestoreProgressScreen({super.key, required this.jobId});

  final String jobId;

  @override
  ConsumerState<RestoreProgressScreen> createState() => _RestoreProgressScreenState();
}

const _terminalStates = {'succeeded', 'failed'};

class _RestoreProgressScreenState extends ConsumerState<RestoreProgressScreen> {
  PapraBackupRestoreJob? _job;
  bool _loading = true;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _poll();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
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
    try {
      final job = await client.getBackupRestoreJob(widget.jobId);
      if (!mounted) return;
      setState(() {
        _job = job;
        _loading = false;
        _error = null;
      });
      if (job == null || _terminalStates.contains(job.status)) return;
      _timer = Timer(const Duration(seconds: 2), _poll);
    } on PapraApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
      _timer = Timer(const Duration(seconds: 4), _poll);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not reach the server. Retrying…';
      });
      _timer = Timer(const Duration(seconds: 4), _poll);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Restore progress')),
      body: _buildBody(scheme),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading && _job == null) {
      return const LoadingState(label: 'Loading restore job…');
    }
    final job = _job;
    if (job == null) {
      return ErrorState(message: _error ?? 'Restore job not found.');
    }

    final isTerminal = _terminalStates.contains(job.status);
    final succeeded = job.status == 'succeeded';
    final downloadEta = _describeDownloadPhase(job);
    final restoreEta = _describeRestorePhase(job);

    return ListView(
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
                    Icon(
                      succeeded
                          ? Icons.check_circle
                          : job.status == 'failed'
                              ? Icons.error
                              : Icons.hourglass_top,
                      color: succeeded
                          ? Colors.green
                          : job.status == 'failed'
                              ? scheme.error
                              : scheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _statusLabel(job.status),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (!isTerminal)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                  ],
                ),
                if (job.errorMessage != null && job.errorMessage!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    job.errorMessage!,
                    style: TextStyle(color: scheme.error),
                  ),
                ],
                const SizedBox(height: 16),
                _progressBar(
                  label: 'Downloading',
                  value: downloadEta.percent,
                  detail: downloadEta.label,
                ),
                const SizedBox(height: 12),
                _progressBar(
                  label: 'Restoring documents',
                  value: restoreEta.percent,
                  detail: restoreEta.label,
                ),
                if (isTerminal) ...[
                  const Divider(height: 32),
                  _countRow('Restored documents', job.restoredDocumentsCount),
                  _countRow('Untrashed documents', job.untrashedDocumentsCount),
                  _countRow('Skipped duplicates', job.skippedDuplicatesCount),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Started ${formatDate(job.createdAt)}'
          '${job.completedAt != null && job.completedAt!.isNotEmpty ? ' · finished ${formatDate(job.completedAt!)}' : ''}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  /// Rough ETA from average throughput so far — good enough to be useful
  /// without pretending to a precision the data doesn't have. Mirrors the
  /// server web client's estimateRestoreEta.
  ({String label, double? percent}) _describeDownloadPhase(PapraBackupRestoreJob job) {
    final downloaded = job.downloadedBytes;
    final total = job.totalBytes;

    if (job.status != 'downloading') {
      if (downloaded != null && downloaded > 0) {
        final percent = total != null && total > 0 ? (downloaded / total).clamp(0.0, 1.0) : null;
        return (label: '${formatBytes(downloaded)} downloaded', percent: percent);
      }
      return (label: '', percent: null);
    }
    if (downloaded == null || downloaded == 0) {
      return (label: 'Waiting for data…', percent: null);
    }

    final sizeLabel = total != null && total > 0
        ? '${formatBytes(downloaded)} / ${formatBytes(total)}'
        : formatBytes(downloaded);

    if (total == null || total <= 0 || job.startedAt == null) {
      return (label: sizeLabel, percent: null);
    }

    final elapsedMs =
        DateTime.now().difference(DateTime.parse(job.startedAt!)).inMilliseconds;
    if (elapsedMs <= 0) return (label: sizeLabel, percent: null);
    final bytesPerMs = downloaded / elapsedMs;
    final remainingMs = ((total - downloaded) / bytesPerMs).round();
    return (
      label: '$sizeLabel · ${formatEtaLabel(remainingMs)}',
      percent: (downloaded / total).clamp(0.0, 1.0),
    );
  }

  ({String label, double? percent}) _describeRestorePhase(PapraBackupRestoreJob job) {
    final total = job.totalDocumentsCount;
    final processed = job.processedDocumentsCount;

    if (job.status == 'pending') return (label: 'Starting…', percent: null);
    if (!job.isRestoringPhase) {
      if (total == null || total == 0) return (label: '', percent: null);
      return (label: '$processed/$total documents', percent: processed / total);
    }
    if (total == null || total == 0) return (label: 'Preparing…', percent: null);

    final percent = (processed / total).clamp(0.0, 1.0);
    if (job.startedAt == null || processed == 0) {
      return (label: '$processed/$total documents', percent: percent);
    }

    final elapsedMs =
        DateTime.now().difference(DateTime.parse(job.startedAt!)).inMilliseconds;
    if (elapsedMs <= 0) return (label: '$processed/$total documents', percent: percent);
    final perDocumentMs = elapsedMs / processed;
    final remainingMs = ((total - processed) * perDocumentMs).round();
    return (
      label: '$processed/$total documents · ${formatEtaLabel(remainingMs)}',
      percent: percent,
    );
  }

  String _statusLabel(String status) => switch (status) {
        'pending' => 'Waiting to start…',
        'downloading' => 'Downloading backup…',
        'restoring' => 'Restoring documents…',
        'succeeded' => 'Restore complete',
        'failed' => 'Restore failed',
        _ => status,
      };

  Widget _progressBar({
    required String label,
    required double? value,
    required String detail,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            Text(detail, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: value),
      ],
    );
  }

  Widget _countRow(String label, int? value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text('${value ?? 0}', style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
