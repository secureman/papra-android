import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'network/session_cookie_store.dart';
import 'storage/secure_store.dart';
import 'storage/settings_store.dart';

final secureStoreProvider = Provider<SecureStore>((ref) => SecureStore());

final sessionCookieStoreProvider = Provider<SessionCookieStore>(
  (ref) => SessionCookieStore(ref.watch(secureStoreProvider)),
);

final settingsStoreProvider = Provider<SettingsStore>((ref) => SettingsStore());
