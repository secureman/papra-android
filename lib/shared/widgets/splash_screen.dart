import 'package:flutter/material.dart';

import 'papra_logo_mark.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PapraLogoMark(size: 72),
            const SizedBox(height: 20),
            Text(
              'Papra',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 24),
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
          ],
        ),
      ),
    );
  }
}
