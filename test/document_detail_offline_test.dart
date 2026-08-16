import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papra_android/core/network/api_client.dart';
import 'package:papra_android/core/network/api_exception.dart';
import 'package:papra_android/core/network/models.dart';
import 'package:papra_android/core/network/session_cookie_store.dart';
import 'package:papra_android/core/storage/document_cache.dart';
import 'package:papra_android/core/storage/secure_store.dart';
import 'package:papra_android/features/auth/auth_controller.dart';
import 'package:papra_android/features/documents/document_detail_screen.dart';

/// [ApiClient] whose [getDocument] always fails — simulates being offline.
class _OfflineApiClient extends ApiClient {
  _OfflineApiClient()
      : super(
          baseUrl: 'https://example.com',
          organizationId: 'org-1',
          apiKey: 'key',
          cookieStore: SessionCookieStore(SecureStore()),
          onAuthFailure: () {},
        );

  @override
  Future<PapraDocument> getDocument(String documentId) async {
    throw const PapraApiException(message: 'offline', isNetwork: true);
  }
}

/// In-memory [DocumentCache] stub so tests never touch path_provider. Returns
/// no cached JSON so the screen must fall back to [DocumentDetailScreen.initial].
class _FakeCache extends DocumentCache {
  @override
  Future<Set<String>> getPinnedIds() async => const {};

  @override
  Future<void> setPinned(String documentId, {required bool pinned}) async {}

  @override
  Future<Map<String, dynamic>?> readJson(String key) async => null;

  @override
  Future<void> writeJson(String key, Map<String, dynamic> data) async {}
}

PapraDocument _doc(String id, String name) => PapraDocument(
      id: id,
      name: name,
      createdAt: '2026-01-01T00:00:00Z',
      size: 1024,
      mimeType: 'application/octet-stream',
    );

void main() {
  testWidgets('shows cached document data instead of an error when offline',
      (tester) async {
    final client = _OfflineApiClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(client),
          documentCacheProvider.overrideWithValue(_FakeCache()),
        ],
        child: MaterialApp(
          home: DocumentDetailScreen(
            documentId: '1',
            initial: _doc('1', 'invoice.docx'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The offline notice replaces the error state…
    expect(
      find.text("You're offline — showing the saved copy. The original file is still available."),
      findsOneWidget,
    );
    expect(find.text('offline'), findsNothing);

    // …and the saved copy stays reachable: title, metadata and the actions
    // needed to open the cached file are all present.
    expect(find.text('invoice.docx'), findsOneWidget);
    expect(find.text('View original file'), findsOneWidget);
    expect(find.text('Available offline'), findsOneWidget);
  });

  testWidgets('shows the error when offline and nothing is cached',
      (tester) async {
    final client = _OfflineApiClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(client),
          documentCacheProvider.overrideWithValue(_FakeCache()),
        ],
        child: MaterialApp(
          home: DocumentDetailScreen(documentId: '1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('offline'), findsOneWidget);
    expect(find.text('View original file'), findsNothing);
  });
}
