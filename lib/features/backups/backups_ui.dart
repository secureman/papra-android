import 'package:flutter/material.dart';

import '../../core/network/models.dart';

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
      'uploading' => 'Uploading',
      'succeeded' => 'Succeeded',
      'failed' => 'Failed',
      _ => status,
    };

IconData backupStatusIcon(String status) => switch (status) {
      'succeeded' => Icons.check_circle,
      'failed' => Icons.error_outline,
      'pending' => Icons.hourglass_top,
      _ => Icons.upload,
    };
