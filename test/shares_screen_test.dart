import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papra_android/core/network/api_client.dart';
import 'package:papra_android/core/network/models.dart';
import 'package:papra_android/core/network/session_cookie_store.dart';
import 'package:papra_android/core/storage/secure_store.dart';
import 'package:papra_android/features/auth/auth_controller.dart';
import 'package:papra_android/features/shares/shares_screen.dart';

/// In-memory [ApiClient] stub recording every share-link call, so the Shares
/// screen can be exercised end-to-end without a network.
class _FakeApiClient extends ApiClient {
  _FakeApiClient()
      : super(
          baseUrl: 'https://example.com',
          organizationId: 'org-1',
          apiKey: 'key',
          cookieStore: SessionCookieStore(SecureStore()),
          onAuthFailure: () {},
        );

  List<PapraShareLink> links = [];
  List<PapraDocument> documents = [];

  final createdLinks =
      <({String documentId, String? expiresAt, String? password})>[];
  final updatedLinks = <
      ({
        String id,
        String? expiresAt,
        String? password,
        bool? isEnabled,
        bool clearExpiresAt,
        bool clearPassword,
      })>[];
  final deletedLinkIds = <String>[];

  @override
  Future<List<PapraShareLink>> listOrganizationShareLinks() async => links;

  @override
  Future<DocumentsResponse> listDocuments({
    String search = '',
    int pageIndex = 0,
    int pageSize = 100,
    String sortField = 'createdAt',
    String sortOrder = 'desc',
  }) async {
    final filtered = documents
        .where((d) => d.name.toLowerCase().contains(search.trim().toLowerCase()))
        .toList();
    return DocumentsResponse(documents: filtered, documentsCount: filtered.length);
  }

  @override
  Future<void> createShareLink(
    String documentId, {
    String? expiresAt,
    String? password,
  }) async {
    createdLinks
        .add((documentId: documentId, expiresAt: expiresAt, password: password));
  }

  @override
  Future<void> updateShareLink(
    String shareLinkId, {
    String? expiresAt,
    String? password,
    bool? isEnabled,
    bool clearExpiresAt = false,
    bool clearPassword = false,
  }) async {
    updatedLinks.add((
      id: shareLinkId,
      expiresAt: expiresAt,
      password: password,
      isEnabled: isEnabled,
      clearExpiresAt: clearExpiresAt,
      clearPassword: clearPassword,
    ));
  }

  @override
  Future<void> deleteShareLink(String shareLinkId) async {
    deletedLinkIds.add(shareLinkId);
  }
}

PapraShareLink _link({
  String id = 'sl-1',
  String documentId = 'd-1',
  String documentName = 'invoice.pdf',
  bool enabled = true,
  bool passwordProtected = false,
  String? expiresAt,
  bool documentDeleted = false,
}) =>
    PapraShareLink(
      id: id,
      documentId: documentId,
      url: 'https://docs.example.com/share/abc123',
      token: 'abc123',
      isPasswordProtected: passwordProtected,
      isEnabled: enabled,
      expiresAt: expiresAt,
      documentName: documentName,
      isDocumentDeleted: documentDeleted,
    );

PapraDocument _doc(String id, String name) => PapraDocument(
      id: id,
      name: name,
      createdAt: '2026-01-01T00:00:00Z',
      size: 1024,
      mimeType: 'application/octet-stream',
    );

Future<void> _pumpShares(WidgetTester tester, _FakeApiClient client) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: const MaterialApp(home: SharesScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Lets the snackbar auto-dismiss timer fire so no timers are left pending.
Future<void> _flushSnackbar(WidgetTester tester) async {
  await tester.pumpAndSettle(const Duration(seconds: 5));
}

void main() {
  testWidgets('shows the empty state when there are no share links',
      (tester) async {
    final client = _FakeApiClient();
    await _pumpShares(tester, client);

    expect(find.text('No share links yet'), findsOneWidget);
    expect(find.text('New link'), findsOneWidget);
  });

  testWidgets('lists share links with document name and meta', (tester) async {
    final client = _FakeApiClient()
      ..links = [
        _link(
          documentName: 'invoice.pdf',
          passwordProtected: true,
          expiresAt: '2026-12-31T00:00:00.000Z',
        ),
        _link(id: 'sl-2', documentId: 'd-2', documentName: 'receipt.xlsx', enabled: false),
        _link(id: 'sl-3', documentId: 'd-3', documentName: 'letter.docx', documentDeleted: true),
      ];
    await _pumpShares(tester, client);

    expect(find.text('invoice.pdf'), findsOneWidget);
    expect(find.text('receipt.xlsx'), findsOneWidget);
    expect(find.text('letter.docx'), findsOneWidget);
    // URL is displayed for every link.
    expect(find.text('https://docs.example.com/share/abc123'), findsNWidgets(3));
    expect(find.textContaining('Password protected'), findsOneWidget);
    expect(find.textContaining('Expires Dec 31, 2026'), findsOneWidget);
    expect(find.textContaining('Disabled'), findsOneWidget);
    expect(find.textContaining('Document in trash'), findsOneWidget);
  });

  testWidgets('copies the link URL to the clipboard', (tester) async {
    final client = _FakeApiClient()..links = [_link()];
    final clipboardCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        clipboardCalls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await _pumpShares(tester, client);
    await tester.tap(find.byIcon(Icons.copy));
    await tester.pump();

    final setData = clipboardCalls.where((c) => c.method == 'Clipboard.setData');
    expect(setData, hasLength(1));
    expect(
      (setData.first.arguments as Map)['text'],
      'https://docs.example.com/share/abc123',
    );
    expect(find.textContaining('Link copied'), findsOneWidget);
    await _flushSnackbar(tester);
  });

  testWidgets('creates a share link by picking a document', (tester) async {
    final client = _FakeApiClient()
      ..documents = [_doc('d-1', 'invoice.pdf'), _doc('d-2', 'receipt.xlsx')];
    await _pumpShares(tester, client);

    await tester.tap(find.text('New link'));
    await tester.pumpAndSettle();
    expect(find.text('Select a document'), findsOneWidget);

    await tester.tap(find.text('invoice.pdf'));
    await tester.pumpAndSettle();
    expect(find.text('New share link'), findsOneWidget);

    // Leave expiry off and password empty, then save.
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(client.createdLinks, hasLength(1));
    expect(client.createdLinks.single.documentId, 'd-1');
    expect(client.createdLinks.single.expiresAt, isNull);
    expect(client.createdLinks.single.password, isNull);
    expect(find.textContaining('Share link created'), findsOneWidget);
    await _flushSnackbar(tester);
  });

  testWidgets('edits a link: sets a new password and keeps the expiry',
      (tester) async {
    final client = _FakeApiClient()
      ..links = [_link(expiresAt: '2026-12-31T00:00:00.000Z')];
    await _pumpShares(tester, client);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit share link'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'secret');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(client.updatedLinks, hasLength(1));
    final update = client.updatedLinks.single;
    expect(update.id, 'sl-1');
    expect(update.password, 'secret');
    expect(update.expiresAt, '2026-12-31T00:00:00.000Z');
    expect(update.clearExpiresAt, isFalse);
    expect(find.textContaining('Share link updated'), findsOneWidget);
    await _flushSnackbar(tester);
  });

  testWidgets('sends the expiry as a UTC ISO timestamp (with Z)', (tester) async {
    // The fork's `v.isoTimestamp()` schema rejects timestamps without a
    // timezone, so a local `toIso8601String()` (no Z) must never be sent.
    final client = _FakeApiClient()
      ..links = [_link(expiresAt: '2026-12-31T00:00:00.000')];
    await _pumpShares(tester, client);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final expiresAt = client.updatedLinks.single.expiresAt;
    expect(expiresAt, isNotNull);
    expect(expiresAt!.endsWith('Z'), isTrue);
    // Same instant as the input date, just normalized to UTC.
    expect(
      DateTime.parse(expiresAt),
      DateTime.parse('2026-12-31T00:00:00.000').toUtc(),
    );
    await _flushSnackbar(tester);
  });

  testWidgets('disables a link from the menu', (tester) async {
    final client = _FakeApiClient()..links = [_link()];
    await _pumpShares(tester, client);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disable'));
    await tester.pumpAndSettle();

    expect(client.updatedLinks, hasLength(1));
    expect(client.updatedLinks.single.id, 'sl-1');
    expect(client.updatedLinks.single.isEnabled, isFalse);
    expect(find.textContaining('Link disabled'), findsOneWidget);
    await _flushSnackbar(tester);
  });

  testWidgets('deletes a link only after confirmation', (tester) async {
    final client = _FakeApiClient()..links = [_link()];
    await _pumpShares(tester, client);

    // Cancelling keeps the link.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete share link?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(client.deletedLinkIds, isEmpty);

    // Confirming deletes it.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(client.deletedLinkIds, ['sl-1']);
    expect(find.textContaining('Share link deleted'), findsOneWidget);
    await _flushSnackbar(tester);
  });
}
