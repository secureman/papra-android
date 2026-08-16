import 'package:flutter_test/flutter_test.dart';
import 'package:papra_android/core/network/models.dart';

void main() {
  group('DocumentsResponse', () {
    test('parses the fork enriched-document shape', () {
      final json = {
        'documents': [
          {
            'id': 'doc-1',
            'name': 'invoice.pdf',
            'createdAt': '2026-01-02T10:00:00Z',
            'originalSize': 2048,
            'mimeType': 'application/pdf',
            'content': 'Invoice from ACME',
            'tags': [
              {'id': 'tag-1', 'name': 'invoice', 'color': '#ff0000'}
            ],
            'folderId': 'folder-1',
            'customProperties': [
              {
                'key': 'vendor',
                'name': 'Vendor',
                'type': 'text',
                'displayOrder': 0,
                'value': 'ACME',
              },
            ],
          },
        ],
        'documentsCount': 1,
      };
      final response = DocumentsResponse.fromJson(json);
      expect(response.documentsCount, 1);
      final doc = response.documents.single;
      expect(doc.name, 'invoice.pdf');
      expect(doc.size, 2048);
      expect(doc.tags.single.name, 'invoice');
      expect(doc.folderId, 'folder-1');
      expect(doc.content, 'Invoice from ACME');
      expect(doc.customProperties.single.key, 'vendor');
      expect(doc.customProperties.single.value, 'ACME');
    });

    test('handles missing optional fields', () {
      final json = {
        'documents': [
          {'id': 'doc-2', 'name': 'scan.png', 'createdAt': '2026-01-01T00:00:00Z'},
        ],
      };
      final doc = DocumentsResponse.fromJson(json).documents.single;
      expect(doc.size, 0);
      expect(doc.tags, isEmpty);
      expect(doc.customProperties, isEmpty);
      expect(doc.content, '');
      expect(doc.isDeleted, false);
    });
  });

  group('OrganizationsResponse', () {
    test('parses organizations', () {
      final json = {
        'organizations': [
          {'id': 'org-1', 'name': 'Acme'},
          {'id': 'org-2', 'name': 'Globex'},
        ],
      };
      final orgs = OrganizationsResponse.fromJson(json).organizations;
      expect(orgs, hasLength(2));
      expect(orgs.first.name, 'Acme');
    });
  });

  group('DeviceApiKeyResponse', () {
    test('extracts the top-level token (the fork response shape)', () {
      final json = {
        'apiKey': {'id': 'key-1', 'name': 'device'},
        'token': 'papra_live_abc123',
      };
      expect(DeviceApiKeyResponse.fromJson(json).token, 'papra_live_abc123');
    });

    test('falls back to the nested apiKey.token shape', () {
      final json = {
        'apiKey': {'id': 'key-1', 'name': 'device', 'token': 'papra_live_abc123'},
      };
      expect(DeviceApiKeyResponse.fromJson(json).token, 'papra_live_abc123');
    });
  });

  group('TaggingRule', () {
    test('parses the fork aggregated shape (actions, conditionMatchMode)', () {
      final json = {
        'id': 'rule-1',
        'name': 'Invoice auto-tag',
        'description': 'Tags invoices',
        'enabled': true,
        'conditionMatchMode': 'all',
        'conditions': [
          {'field': 'name', 'operator': 'contains', 'value': 'invoice'},
          {
            'field': 'content',
            'operator': 'starts_with',
            'value': 'Invoice',
            'isCaseSensitive': true,
          },
        ],
        'actions': [
          {
            'id': 'action-1',
            'tagId': 'tag-1',
            'tag': {'id': 'tag-1', 'name': 'invoice', 'color': '#ff0000'},
          },
          {'id': 'action-2', 'tagId': 'tag-2', 'tag': null},
        ],
      };
      final rule = PapraTaggingRule.fromJson(json);
      expect(rule.conditionMatchMode, 'all');
      expect(rule.description, 'Tags invoices');
      expect(rule.conditions, hasLength(2));
      expect(rule.conditions.first.operator, 'contains');
      expect(rule.conditions.last.isCaseSensitive, true);
      expect(rule.tagIds, ['tag-1', 'tag-2']);
    });

    test('falls back to a flat tagIds array', () {
      final json = {
        'id': 'rule-2',
        'name': 'Simple',
        'enabled': true,
        'conditionMatchMode': 'any',
        'conditions': [],
        'tagIds': ['tag-9'],
      };
      final rule = PapraTaggingRule.fromJson(json);
      expect(rule.tagIds, ['tag-9']);
    });
  });

  group('IntakeEmail', () {
    test('parses the fork emailAddress field', () {
      final json = {
        'id': 'ie-1',
        'emailAddress': 'hello@inbox.example.com',
        'isEnabled': true,
        'allowedOrigins': ['example.com'],
      };
      final email = PapraIntakeEmail.fromJson(json);
      expect(email.emailAddress, 'hello@inbox.example.com');
      expect(email.enabled, true);
      expect(email.allowedOrigins, ['example.com']);
    });
  });

  group('CustomProperty', () {
    test('parses the fork propertyDefinitions shape', () {
      final json = {
        'id': 'cp-1',
        'name': 'Vendor',
        'key': 'vendor',
        'type': 'select',
        'displayOrder': 0,
      };
      final property = PapraCustomProperty.fromJson(json);
      expect(property.key, 'vendor');
      expect(property.type, 'select');
      expect(property.displayOrder, 0);
    });
  });
}
