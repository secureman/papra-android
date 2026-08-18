import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // pdfrx is initialized lazily by the first widget that needs its document
  // API (thumbnail rendering), keeping it off the startup path.
  runApp(const ProviderScope(child: PapraApp()));
}