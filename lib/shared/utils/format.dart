import 'package:intl/intl.dart';

/// Formats a byte count as a human-readable size (e.g. "2.4 MB").
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Formats an ISO-8601 timestamp as "Aug 1, 2026" (local time).
String formatDate(String iso) {
  if (iso.isEmpty) return '';
  try {
    return DateFormat('MMM d, yyyy').format(DateTime.parse(iso).toLocal());
  } catch (_) {
    return iso;
  }
}
