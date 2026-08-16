import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papra_android/core/network/api_client.dart';
import 'package:papra_android/core/network/models.dart';
import 'package:papra_android/core/network/session_cookie_store.dart';
import 'package:papra_android/core/storage/document_cache.dart';
import 'package:papra_android/core/storage/secure_store.dart';
import 'package:papra_android/features/auth/auth_controller.dart';
import 'package:papra_android/features/documents/documents_screen.dart';

/// In-memory [ApiClient] stub for the Documents screen's folder browsing.
class _FakeApiClient extends ApiClient {
  _FakeApiClient()
      : super(
          baseUrl: 'https://example.com',
          organizationId: 'org-1',
          apiKey: 'key',
          cookieStore: SessionCookieStore(SecureStore()),
          onAuthFailure: () {},
        );

  FolderContentsResponse folderContents =
      const FolderContentsResponse(folders: [], documents: []);
  final requestedFolderIds = <String?>[];

  @override
  Future<FolderContentsResponse> getFolderContents({String? folderId}) async {
    requestedFolderIds.add(folderId);
    return folderContents;
  }
}

/// In-memory cache stub — the real one does file I/O, which hangs in the
/// fake-async widget-test zone.
class _FakeCache extends DocumentCache {
  @override
  Future<Map<String, dynamic>?> readJson(String key) async => null;

  @override
  Future<void> writeJson(String key, Map<String, dynamic> data) async {}

  @override
  Future<Set<String>> getPinnedIds() async => const {};
}

Future<void> _pumpDocuments(WidgetTester tester, _FakeApiClient client,
    {String? folderId, String? folderName}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        documentCacheProvider.overrideWithValue(_FakeCache()),
      ],
      child: MaterialApp(
        home: DocumentsScreen(
          initialFolderId: folderId,
          initialFolderName: folderName,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('deep-linked initial folder opens its contents with a breadcrumb',
      (tester) async {
    // Non-thumbnailable name/mime so no file download is attempted.
    final client = _FakeApiClient()
      ..folderContents = const FolderContentsResponse(
        folders: [],
        documents: [
          PapraDocument(
            id: 'd-1',
            name: 'invoice.docx',
            createdAt: '2026-01-01T00:00:00Z',
            size: 1024,
            mimeType: 'application/octet-stream',
          ),
        ],
      );

    await _pumpDocuments(tester, client,
        folderId: 'f-1', folderName: 'Invoices');

    // Browsed the requested folder and rendered its documents.
    expect(client.requestedFolderIds, ['f-1']);
    expect(find.text('Invoices'), findsOneWidget); // breadcrumb chip
    expect(find.text('invoice.docx'), findsOneWidget);
  });

  testWidgets('without an initial folder it browses the organization root',
      (tester) async {
    final client = _FakeApiClient();
    await _pumpDocuments(tester, client);

    expect(client.requestedFolderIds, [null]);
    expect(find.text('No documents yet'), findsOneWidget);
  });
}
