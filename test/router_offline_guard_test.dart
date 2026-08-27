import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:papra_android/features/auth/auth_controller.dart';
import 'package:papra_android/features/auth/auth_state.dart';
import 'package:papra_android/features/offline/offline_providers.dart';
import 'package:papra_android/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Auth controller stub pinned to a fixed state, so tests exercise the
/// router's redirect guard without touching secure storage or the network.
class _PinnedAuthController extends AuthController {
  _PinnedAuthController(this.pinned);

  final AuthState pinned;

  @override
  AuthState build() => pinned;
}

/// Snapshot controller stub: no imported backup, resolved without any disk
/// or platform-channel I/O (which never completes in the fake-async zone).
class _EmptySnapshotController extends OfflineSnapshotController {
  @override
  Future<OfflineSnapshotData?> build() async => null;
}

/// Regression tests for the auth redirect guard: the offline backup browser
/// and the local-file PDF viewer must stay reachable while signed out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<GoRouter> pumpSignedOut(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(
          () => _PinnedAuthController(const AuthUnauthenticated()),
        ),
        offlineSnapshotProvider.overrideWith(_EmptySnapshotController.new),
      ],
    );
    addTearDown(container.dispose);
    final router = container.read(routerProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('signed-out users start at login', (tester) async {
    final router = await pumpSignedOut(tester);
    expect(router.routerDelegate.currentConfiguration.uri, Uri(path: '/login'));
  });

  testWidgets('offline routes stay reachable when signed out', (tester) async {
    final router = await pumpSignedOut(tester);

    router.go('/offline');
    await tester.pumpAndSettle();
    expect(
      router.routerDelegate.currentConfiguration.last.matchedLocation,
      '/offline',
    );
  });

  testWidgets('signed-out users can open /document-viewer', (tester) async {
    final router = await pumpSignedOut(tester);

    router.push('/document-viewer', extra: (filePath: '', fileName: 'test.pdf'));
    await tester.pumpAndSettle();
    expect(
      router.routerDelegate.currentConfiguration.last.matchedLocation,
      '/document-viewer',
    );
  });
}
