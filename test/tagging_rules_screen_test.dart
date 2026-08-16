import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papra_android/core/network/api_client.dart';
import 'package:papra_android/core/network/models.dart';
import 'package:papra_android/core/network/session_cookie_store.dart';
import 'package:papra_android/core/storage/secure_store.dart';
import 'package:papra_android/features/auth/auth_controller.dart';
import 'package:papra_android/features/tagging_rules/tagging_rules_screen.dart';

/// In-memory [ApiClient] stub recording every tagging-rule call so the screen
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

  List<PapraTaggingRule> rules = [];
  List<PapraTag> tags = [];

  final createdRules =
      <({
        String name,
        String? description,
        bool enabled,
        String conditionMatchMode,
        List<PapraTaggingCondition> conditions,
        List<String> tagIds,
      })>[];
  final updatedRules =
      <({
        String id,
        String? name,
        String? description,
        bool? enabled,
        String? conditionMatchMode,
        List<PapraTaggingCondition>? conditions,
        List<String>? tagIds,
      })>[];
  final deletedRuleIds = <String>[];
  final appliedRuleIds = <String>[];

  @override
  Future<List<PapraTaggingRule>> listTaggingRules() async => rules;

  @override
  Future<List<PapraTag>> listTags() async => tags;

  @override
  Future<void> createTaggingRule({
    required String name,
    String? description,
    required bool enabled,
    String conditionMatchMode = 'all',
    required List<PapraTaggingCondition> conditions,
    required List<String> tagIds,
  }) async {
    createdRules.add((
      name: name,
      description: description,
      enabled: enabled,
      conditionMatchMode: conditionMatchMode,
      conditions: conditions,
      tagIds: tagIds,
    ));
  }

  @override
  Future<void> updateTaggingRule(
    String ruleId, {
    String? name,
    String? description,
    bool? enabled,
    String? conditionMatchMode,
    List<PapraTaggingCondition>? conditions,
    List<String>? tagIds,
  }) async {
    updatedRules.add((
      id: ruleId,
      name: name,
      description: description,
      enabled: enabled,
      conditionMatchMode: conditionMatchMode,
      conditions: conditions,
      tagIds: tagIds,
    ));
  }

  @override
  Future<void> deleteTaggingRule(String ruleId) async {
    deletedRuleIds.add(ruleId);
  }

  @override
  Future<String> applyTaggingRuleToExisting(String ruleId) async {
    appliedRuleIds.add(ruleId);
    return 'task-1';
  }
}

const _invoiceTag = PapraTag(id: 'tag-1', name: 'Invoice', color: '#e53935');
const _receiptTag = PapraTag(id: 'tag-2', name: 'Receipt', color: '#1e88e5');

PapraTaggingRule _rule({
  String id = 'tr-1',
  String name = 'Invoice rule',
  String? description,
  bool enabled = true,
  String conditionMatchMode = 'all',
  List<PapraTaggingCondition> conditions = const [
    PapraTaggingCondition(field: 'name', operator: 'contains', value: 'invoice'),
  ],
  List<String> tagIds = const ['tag-1'],
}) =>
    PapraTaggingRule(
      id: id,
      name: name,
      description: description,
      enabled: enabled,
      conditionMatchMode: conditionMatchMode,
      conditions: conditions,
      tagIds: tagIds,
    );

Future<void> _pumpRules(WidgetTester tester, _FakeApiClient client) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: const MaterialApp(home: TaggingRulesScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Lets the snackbar auto-dismiss timer fire so no timers are left pending.
Future<void> _flushSnackbar(WidgetTester tester) async {
  await tester.pumpAndSettle(const Duration(seconds: 5));
}

void main() {
  testWidgets('shows the empty state when there are no rules', (tester) async {
    final client = _FakeApiClient()..tags = [_invoiceTag];
    await _pumpRules(tester, client);

    expect(find.text('No tagging rules yet'), findsOneWidget);
    expect(find.text('New rule'), findsOneWidget);
  });

  testWidgets('lists rules with conditions, tags and description',
      (tester) async {
    final client = _FakeApiClient()
      ..tags = [_invoiceTag, _receiptTag]
      ..rules = [
        _rule(description: 'Tags invoice documents'),
        _rule(
          id: 'tr-2',
          name: 'Any-name rule',
          enabled: false,
          conditionMatchMode: 'any',
          conditions: const [
            PapraTaggingCondition(field: 'name', operator: 'starts_with', value: 'letter'),
            PapraTaggingCondition(field: 'content', operator: 'contains', value: 'urgent'),
          ],
          tagIds: ['tag-2'],
        ),
      ];
    await _pumpRules(tester, client);

    expect(find.text('Invoice rule'), findsOneWidget);
    expect(find.text('Tags invoice documents'), findsOneWidget);
    expect(find.textContaining('name contains'), findsOneWidget);
    expect(find.text('Tags: Invoice'), findsOneWidget);

    expect(find.text('Any-name rule'), findsOneWidget);
    expect(
      find.textContaining('Any of: Document name starts with “letter”; Document content contains “urgent”'),
      findsOneWidget,
    );
    expect(find.text('Tags: Receipt'), findsOneWidget);
  });

  testWidgets('creates a rule with a condition and a tag', (tester) async {
    final client = _FakeApiClient()..tags = [_invoiceTag, _receiptTag];
    await _pumpRules(tester, client);

    await tester.tap(find.text('New rule'));
    await tester.pumpAndSettle();
    expect(find.text('New tagging rule'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Invoice rule');
    await tester.ensureVisible(find.text('Add condition'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add condition'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'invoice');
    await tester.ensureVisible(find.text('Invoice')); // tag FilterChip
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invoice'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(client.createdRules, hasLength(1));
    final created = client.createdRules.single;
    expect(created.name, 'Invoice rule');
    expect(created.description, isNull);
    expect(created.enabled, isTrue);
    expect(created.conditionMatchMode, 'all');
    expect(created.conditions, hasLength(1));
    expect(created.conditions.single.field, 'name');
    expect(created.conditions.single.operator, 'contains');
    expect(created.conditions.single.value, 'invoice');
    expect(created.tagIds, ['tag-1']);
    expect(find.textContaining('Rule created'), findsOneWidget);
    await _flushSnackbar(tester);
  });

  testWidgets('validates the rule name before creating', (tester) async {
    final client = _FakeApiClient()..tags = [_invoiceTag];
    await _pumpRules(tester, client);

    await tester.tap(find.text('New rule'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a rule name.'), findsOneWidget);
    expect(client.createdRules, isEmpty);
  });

  testWidgets('edits an existing rule', (tester) async {
    final client = _FakeApiClient()
      ..tags = [_invoiceTag]
      ..rules = [_rule()];
    await _pumpRules(tester, client);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit tagging rule'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Invoice rule'), 'Renamed rule');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(client.updatedRules, hasLength(1));
    final updated = client.updatedRules.single;
    expect(updated.id, 'tr-1');
    expect(updated.name, 'Renamed rule');
    expect(updated.enabled, isTrue);
    expect(updated.conditions, hasLength(1));
    expect(updated.tagIds, ['tag-1']);
    expect(find.textContaining('Rule updated'), findsOneWidget);
    await _flushSnackbar(tester);
  });

  testWidgets('toggles a rule off with the switch', (tester) async {
    final client = _FakeApiClient()
      ..tags = [_invoiceTag]
      ..rules = [_rule()];
    await _pumpRules(tester, client);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(client.updatedRules, hasLength(1));
    expect(client.updatedRules.single.id, 'tr-1');
    expect(client.updatedRules.single.enabled, isFalse);
  });

  testWidgets('applies a rule to existing documents after confirmation',
      (tester) async {
    final client = _FakeApiClient()
      ..tags = [_invoiceTag]
      ..rules = [_rule()];
    await _pumpRules(tester, client);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply to existing documents'));
    await tester.pumpAndSettle();
    expect(find.text('Apply to existing documents?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();

    expect(client.appliedRuleIds, ['tr-1']);
    expect(find.textContaining('Tagging started'), findsOneWidget);
    await _flushSnackbar(tester);
  });

  testWidgets('deletes a rule only after confirmation', (tester) async {
    final client = _FakeApiClient()
      ..tags = [_invoiceTag]
      ..rules = [_rule()];
    await _pumpRules(tester, client);

    // Cancelling keeps the rule.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete tagging rule?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(client.deletedRuleIds, isEmpty);

    // Confirming deletes it.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(client.deletedRuleIds, ['tr-1']);
    expect(find.textContaining('Rule deleted'), findsOneWidget);
    await _flushSnackbar(tester);
  });
}
