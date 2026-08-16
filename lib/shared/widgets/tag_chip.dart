import 'package:flutter/material.dart';

import '../../core/network/models.dart';

/// A pill-shaped chip colored from the tag's hex color, falling back to the
/// theme's secondary color for empty/malformed values.
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.tag});

  final PapraTag tag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Color color = scheme.secondary;
    try {
      final hex = tag.color.replaceFirst('#', '');
      if (hex.length == 6) {
        color = Color(int.parse('FF$hex', radix: 16));
      }
    } catch (_) {
      // Fall back to the theme color for malformed hex values.
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        tag.name,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: Color.lerp(color, Colors.black, 0.4)),
      ),
    );
  }
}
