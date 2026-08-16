import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papra_android/core/network/api_client.dart';
import 'package:papra_android/core/network/models.dart';
import 'package:papra_android/core/network/session_cookie_store.dart';
import 'package:papra_android/core/storage/secure_store.dart';
import 'package:papra_android/features/auth/auth_controller.dart';
import 'package:papra_android/features/intake_emails/intake_emails_screen.dart';

/// In-memory [ApiClient] stub recording every intake-email call so the screen
/// can be exercised end-to-end without a network.
class _FakeApiClient extends ApiClient {
  _FakeApiClient()
      : super(
          baseUrl: 'https://example.com',
          organizationId: 'org-1',
          apiKey: 'key',
          cookieStore: SessionCookieStore(SecureStore()),
          onAuthFailure: () {},
        );

  List<PapraIntakeEmail> emails = [];

  int createCalls = 0;
  final updatedEmails =
      <({String id, bool? isEnabled, List<String>? allowedOrigins})>[];
  final deletedEmailIds = <String>[];

  @override
  Future<List<PapraIntakeEmail>> listIntakeEmails() async => emails;

  @override
  Future<void> createIntakeEmail() async {
    createCalls++;
  }

  @override
  Future<void> updateIntakeEmail(
    String intakeEmailId, {
    bool? isEnabled,
    List<String>? allowedOrigins,
  }) async {
    updatedEmails.add((id: intakeEmailId, isEnabled: isEnabled, allowedOrigins: allowedOrigins));
  }

  @override
  Future<void> deleteIntakeEmail(String intakeEmailId) async {
    deletedEmailIds.add(intakeEmailId);
  }
}

PapraIntakeEmail _email({
  String id = 'ie-1',
  String address = 'inbox@example.com',
  bool enabled = true,
  String? createdAt,
  List<String> allowedOrigins = const [],
}) =>
    PapraIntakeEmail(
      id: id,
      emailAddress: address,
      enabled: enabled,
      createdAt: createdAt,
      allowedOrigins: allowedOrigins,
    );

Future<void> _pumpEmails(WidgetTester tester, _FakeApiClient client) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: const MaterialApp(home: IntakeEmailsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Lets the snackbar auto-dismiss timer fire so no timers are left pending.
Future<void> _flushSnackbar(WidgetTester tester) async {
  await tester.pumpAndSettle(const Duration(seconds: 5));
}

void main() {
  testWidgets('shows the empty state when there are no intake emails',
      (tester) async {
    final client = _FakeApiClient();
    await _pumpEmails(tester, client);

    expect(find.text('No intake emails yet'), findsOneWidget);
    expect(find.text('New address'), findsOneWidget);
  });

  testWidgets('lists intake emails with status and allowed senders',
      (tester) async {
    final client = _FakeApiClient()
      ..emails = [
        _email(createdAt: '2026-01-01T00:00:00Z'),
        _email(
          id: 'ie-2',
          address: 'vendor@example.com',
          enabled: false,
        ),
        _email(
          id: 'ie-3',
          address: 'hr@example.com',
          allowedOrigins: ['alice@corp.com', 'bob@corp.com'],
        ),
      ];
    await _pumpEmails(tester, client);

    expect(find.text('inbox@example.com'), findsOneWidget);
    expect(find.text('Accepts mail from anyone'), findsOneWidget);
    expect(find.textContaining('Created Jan 1, 2026'), findsOneWidget);

    expect(find.text('vendor@example.com'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);

    expect(find.text('hr@example.com'), findsOneWidget);
    expect(
      find.text('Allowed senders: alice@corp.com, bob@corp.com'),
      findsOneWidget,
    );
  });

  testWidgets('creates a new intake address', (tester) async {
    final client = _FakeApiClient();
    await _pumpEmails(tester, client);

    await tester.tap(find.text('New address'));
    await tester.pumpAndSettle();

    expect(client.createCalls, 1);
    expect(find.textContaining('Intake address created'), findsOneWidget);
    await _flushSnackbar(tester);
  });

  testWidgets('disables an address with the switch', (tester) async {
    final client = _FakeApiClient()..emails = [_email()];
    await _pumpEmails(tester, client);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(client.updatedEmails, hasLength(1));
    expect(client.updatedEmails.single.id, 'ie-1');
    expect(client.updatedEmails.single.isEnabled, isFalse);
    expect(find.textContaining('Address disabled'), findsOneWidget);
    await _flushSnackbar(tester);
  });

  testWidgets('edits allowed senders (lowercased, split per line)',
      (tester) async {
    final client = _FakeApiClient()
      ..emails = [_email(allowedOrigins: ['old@corp.com'])];
    await _pumpEmails(tester, client);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit allowed senders'));
    await tester.pumpAndSettle();
    expect(find.text('Allowed senders'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      'Alice@Corp.com\nbob@corp.com',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(client.updatedEmails, hasLength(1));
    final update = client.updatedEmails.single;
    expect(update.id, 'ie-1');
    expect(update.isEnabled, isNull);
    expect(update.allowedOrigins, ['alice@corp.com', 'bob@corp.com']);
    expect(find.textContaining('Allowed senders updated'), findsOneWidget);
    await _flushSnackbar(tester);
  });

  testWidgets('copies the address to the clipboard', (tester) async {
    final client = _FakeApiClient()..emails = [_email()];
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

    await _pumpEmails(tester, client);
    await tester.tap(find.byIcon(Icons.copy));
    await tester.pump();

    final setData = clipboardCalls.where((c) => c.method == 'Clipboard.setData');
    expect(setData, hasLength(1));
    expect(
      (setData.first.arguments as Map)['text'],
      'inbox@example.com',
    );
    expect(find.textContaining('Address copied'), findsOneWidget);
    await _flushSnackbar(tester);
  });

  testWidgets('deletes an address only after confirmation', (tester) async {
    final client = _FakeApiClient()..emails = [_email()];
    await _pumpEmails(tester, client);

    // Cancelling keeps the address.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete intake address?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(client.deletedEmailIds, isEmpty);

    // Confirming deletes it.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(client.deletedEmailIds, ['ie-1']);
    expect(find.textContaining('Intake address deleted'), findsOneWidget);
    await _flushSnackbar(tester);
  });
}
