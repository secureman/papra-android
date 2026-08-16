import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Required by pdfrx when using document APIs before any viewer widget is
  // built (e.g. for thumbnail rendering). Safe to call unconditionally.
  pdfrxFlutterInitialize();
  runApp(const ProviderScope(child: PapraApp()));
}
