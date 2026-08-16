import 'package:flutter/material.dart';

/// The Papra brand mark: a rounded square soaked in the primary color (lime
/// in dark mode, coral in light mode) with the white Papra document glyph.
///
/// Used on the splash screen, login screen and the drawer header.
class PapraLogoMark extends StatelessWidget {
  const PapraLogoMark({super.key, this.size = 48, this.borderRadius});

  final double size;

  /// Corner radius; defaults to a proportional rounded square.
  final double? borderRadius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(borderRadius ?? size * 0.28),
      ),
      padding: EdgeInsets.all(size * 0.18),
      child: Image.asset(
        'assets/brand/papra_mark.png',
        fit: BoxFit.contain,
        // Fallback so a missing asset never breaks the layout.
        errorBuilder: (context, error, stackTrace) =>
            Icon(Icons.description_outlined, color: scheme.onPrimary),
      ),
    );
  }
}
