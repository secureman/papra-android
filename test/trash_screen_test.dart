import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papra_android/core/network/api_client.dart';
import 'package:papra_android/core/network/models.dart';
import 'package:papra_android/core/network/session_cookie_store.dart';
import 'package:papra_android/core/storage/secure_store.dart';
import 'package:papra_android/features/auth/auth_controller.dart';
import 'package:papra_android/features/trash/trash_screen.dart';

/// In-memory [ApiClient] stub: the real client never touches the network, so
/// the Trash screen can be exercised end-to-end. Documents are named without
/// PDF/image extensions and use an octet-stream mime type so
/// [DocumentThumbnail] is never built (it would try to download a file).
class _FakeApiClient extends ApiClient {
  _FakeApiClient()
      : super(
          baseUrl: 'https://example.com',
          organizationId: 'org-1',
          apiKey: 'key',
          cookieStore: SessionCookieStore(SecureStore()),
          onAuthFailure: () {},
        );

  List<PapraDocument> deleted = [];
  final restoredIds = <String>[];
  final permanentlyDeletedIds = <String>[];
  bool emptyTrashCalled = false;

  int get documentsCount => deleted.length;

  @override
  Future<DocumentsResponse> listDeletedDocuments({
    int pageIndex = 0,
    int pageSize = 100,
  }) async {
    return DocumentsResponse(documents: deleted, documentsCount: documentsCount);
  }

  @override
  Future<void> restoreDocument(String documentId) async {
    restoredIds.add(documentId);
    deleted = deleted.where((d) => d.id != documentId).toList();
  }

  @override
  Future<void> permanentlyDeleteDocument(String documentId) async {
    permanentlyDeletedIds.add(documentId);
    deleted = deleted.where((d) => d.id != documentId).toList();
  }

  @override
  Future<void> emptyTrash() async {
    emptyTrashCalled = true;
    deleted = [];
  }
}

PapraDocument _doc(String id, String name) => PapraDocument(
      id: id,
      name: name,
      createdAt: '2026-01-01T00:00:00Z',
      size: 1024,
      mimeType: 'application/octet-stream',
      isDeleted: true,
      deletedAt: '2026-01-02T00:00:00Z',
    );

Future<void> _pumpTrash(WidgetTester tester, _FakeApiClient client) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: const MaterialApp(home: TrashScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Lets the snackbar auto-dismiss timer fire so no timers are left pending.
Future<void> _flushSnackbar(WidgetTester tester) async {
  await tester.pumpAndSettle(const Duration(seconds: 5));
}

void main() {
  testWidgets('shows the empty state when the trash has no documents',
      (tester) async {
    final client = _FakeApiClient();
    await _pumpTrash(tester, client);

    expect(find.text('Trash is empty'), findsOneWidget);
    // No empty-trash action when there is nothing to empty.
    expect(find.byIcon(Icons.delete_sweep_outlined), findsNothing);
  });

  testWidgets('lists deleted documents', (tester) async {
    final client = _FakeApiClient()
      ..deleted = [_doc('1', 'invoice.docx'), _doc('2', 'receipt.xlsx')];
    await _pumpTrash(tester, client);

    expect(find.text('invoice.docx'), findsOneWidget);
    expect(find.text('receipt.xlsx'), findsOneWidget);
    expect(find.byIcon(Icons.delete_sweep_outlined), findsOneWidget);
  });

  testWidgets('restores a document and removes it from the list',
      (tester) async {
    final client = _FakeApiClient()..deleted = [_doc('1', 'invoice.docx')];
    await _pumpTrash(tester, client);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(client.restoredIds, ['1']);
    expect(find.text('invoice.docx'), findsNothing);
    expect(find.text('Trash is empty'), findsOneWidget);
    expect(find.textContaining('Restored'), findsOneWidget);
    await _flushSnackbar(tester);
  });

  testWidgets('permanently deletes a document only after confirmation',
      (tester) async {
    final client = _FakeApiClient()..deleted = [_doc('1', 'invoice.docx')];
    await _pumpTrash(tester, client);

    // Cancelling the confirmation does nothing.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete forever'));
    await tester.pumpAndSettle();
    expect(find.text('Delete forever?'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(client.permanentlyDeletedIds, isEmpty);
    expect(find.text('invoice.docx'), findsOneWidget);

    // Confirming performs the deletion.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete forever'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete forever'));
    await tester.pumpAndSettle();

    expect(client.permanentlyDeletedIds, ['1']);
    expect(find.text('invoice.docx'), findsNothing);
    expect(find.text('Trash is empty'), findsOneWidget);
    expect(find.textContaining('Deleted'), findsOneWidget);
    await _flushSnackbar(tester);
  });

  testWidgets('empties the trash after confirmation', (tester) async {
    final client = _FakeApiClient()
      ..deleted = [_doc('1', 'invoice.docx'), _doc('2', 'receipt.xlsx')];
    await _pumpTrash(tester, client);

    // Cancelling keeps everything.
    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Empty trash?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(client.emptyTrashCalled, isFalse);
    expect(find.text('invoice.docx'), findsOneWidget);

    // Confirming empties the trash.
    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Empty trash'));
    await tester.pumpAndSettle();

    expect(client.emptyTrashCalled, isTrue);
    expect(find.text('invoice.docx'), findsNothing);
    expect(find.text('receipt.xlsx'), findsNothing);
    expect(find.text('Trash is empty'), findsOneWidget);
    expect(find.textContaining('Trash emptied'), findsOneWidget);
    await _flushSnackbar(tester);
  });
}
