import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../storage/settings_store.dart';

final themeModeProvider = NotifierProvider<ThemeModeController, AppThemeMode>(
  ThemeModeController.new,
);

class ThemeModeController extends Notifier<AppThemeMode> {
  @override
  AppThemeMode build() {
    _load();
    return AppThemeMode.system;
  }

  Future<void> _load() async {
    final settings = await ref.read(settingsStoreProvider).load();
    state = settings.themeMode;
  }

  Future<void> setMode(AppThemeMode mode) async {
    state = mode;
    await ref.read(settingsStoreProvider).save(themeMode: mode);
  }
}
