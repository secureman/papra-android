import 'package:flutter/material.dart';

import '../../core/network/models.dart';
import '../../shared/utils/format.dart';

/// Human-readable driver names + icons for the backup screen.
({IconData icon, String label}) driverInfo(String driver) => switch (driver) {
      'google_drive' => (icon: Icons.cloud, label: 'Google Drive'),
      'webdav' => (icon: Icons.dns_outlined, label: 'WebDAV'),
      'ftp' => (icon: Icons.lan_outlined, label: 'FTP'),
      'local' => (icon: Icons.folder, label: 'Local folder'),
      _ => (icon: Icons.cloud_outlined, label: driver),
    };

const _dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/// "Every day at 03:00", "Sun · Wed · Fri at 03:00", or "Scheduled: off".
String formatSchedule(PapraBackupSchedule schedule) {
  if (!schedule.isEnabled) return 'Scheduled: off';
  final days = schedule.days.isEmpty
      ? 'Every day'
      : schedule.days.map((d) => _dayNames[d]).join(' · ');
  final time = (schedule.hour != null && schedule.minute != null)
      ? 'at ${schedule.hour!.toString().padLeft(2, '0')}:'
            '${schedule.minute!.toString().padLeft(2, '0')}'
      : '';
  return 'Scheduled: $days $time'.trim();
}

String backupStatusLabel(String status) => switch (status) {
      'pending' => 'Pending',
      'packaging' => 'Packaging',
      'uploading' => 'Uploading',
      // Local-folder destinations only: the envelope is built on the server
      // and waits to be claimed by this device.
      'ready_for_download' => 'Saving to your device…',
      'succeeded' => 'Succeeded',
      'failed' => 'Failed',
      _ => status,
    };

IconData backupStatusIcon(String status) => switch (status) {
      'succeeded' => Icons.check_circle,
      'failed' => Icons.error_outline,
      'ready_for_download' => Icons.save_alt,
      'pending' => Icons.hourglass_top,
      _ => Icons.upload,
    };

/// True when a run failed because the destination's OAuth authorization is no
/// longer valid (expired or revoked token), so reconnecting is the fix.
bool isOAuthAuthFailure(String errorMessage) {
  final lower = errorMessage.toLowerCase();
  return lower.contains('oauth') ||
      lower.contains('invalid_grant') ||
      lower.contains('expired or revoked') ||
      lower.contains('authorization expired');
}

/// Rough ETA label from remaining milliseconds — same wording as the restore
/// indicator, honest about being an estimate.
String formatEtaLabel(int remainingMs) {
  if (remainingMs < 5000) return 'almost done';
  if (remainingMs < 60000) return '~${(remainingMs / 1000).ceil()}s left';
  if (remainingMs < 3600000) return '~${(remainingMs / 60000).ceil()}m left';
  return '~${(remainingMs / 3600000).ceil()}h left';
}

/// Real percent for in-flight runs, not just the status word: packaging
/// (reading/taring/encrypting documents) and uploading (sending the finished
/// envelope to the driver) are separate phases with their own totals, so each
/// gets its own bar rather than faking a single 0-100 number across both.
({String label, double? percent}) describeRunProgress(PapraBackupRun run) {
  if (run.status == 'packaging') {
    final total = run.totalRawBytes;
    final processed = run.processedBytes ?? 0;
    if (total == null || total <= 0) {
      return (
        label: 'Reading documents… '
            '${run.processedDocumentsCount}/${run.documentsCount ?? '?'}',
        percent: null,
      );
    }
    return (
      label: 'Packaging… ${formatBytes(processed)} / ${formatBytes(total)} '
          '(${run.processedDocumentsCount}/${run.documentsCount ?? '?'} documents)',
      percent: (processed / total).clamp(0.0, 1.0),
    );
  }
  if (run.status == 'uploading') {
    final total = run.totalSizeBytes;
    final uploaded = run.uploadedBytes;
    if (total == null || total <= 0 || uploaded == null) {
      return (label: 'Uploading…', percent: null);
    }
    return (
      label: 'Uploading… ${formatBytes(uploaded)} / ${formatBytes(total)}',
      percent: (uploaded / total).clamp(0.0, 1.0),
    );
  }
  return (label: backupStatusLabel(run.status), percent: null);
}
