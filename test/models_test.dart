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

  group('FoldersResponse', () {
    test('parses folders with document counts', () {
      final json = {
        'folders': [
          {'id': 'folder-1', 'name': 'Receipts', 'parentId': null, 'documentsCount': 3},
        ],
      };
      final folder = FoldersResponse.fromJson(json).folders.single;
      expect(folder.name, 'Receipts');
      expect(folder.documentsCount, 3);
      expect(folder.parentId, isNull);
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

  group('Backups', () {
    test('parses the backups status response', () {
      final json = {
        'isConfigured': true,
        'drivers': [
          {'name': 'google_drive', 'isConfigured': true},
          {'name': 'webdav', 'isConfigured': true},
          {'name': 'ftp', 'isConfigured': true},
          {'name': 'local', 'isConfigured': true},
        ],
      };
      final status = BackupsStatusResponse.fromJson(json);
      expect(status.isConfigured, true);
      expect(status.drivers, hasLength(4));
      expect(status.drivers.first.name, 'google_drive');
    });

    test('parses a destination with schedule and settings', () {
      final json = {
        'id': 'bkdst-1',
        'driver': 'webdav',
        'displayName': 'NAS',
        'settings': {'baseUrl': 'https://nas.example.com', 'path': '/backups'},
        'accountLabel': 'alice@nas.example.com',
        'isEnabled': true,
        'schedule': {'isEnabled': true, 'days': [1, 3, 5], 'hour': 2, 'minute': 30},
        'lastRunAt': '2026-08-01T01:00:00.000Z',
        'nextScheduledAt': '2026-08-02T02:30:00.000Z',
        'createdAt': '2026-07-01T00:00:00.000Z',
      };
      final destination = PapraBackupDestination.fromJson(json);
      expect(destination.driver, 'webdav');
      expect(destination.settings['baseUrl'], 'https://nas.example.com');
      expect(destination.schedule.days, [1, 3, 5]);
      expect(destination.schedule.hour, 2);
      expect(destination.lastRunAt, '2026-08-01T01:00:00.000Z');
    });

    test('parses a run', () {
      final json = {
        'id': 'bkrn-1',
        'trigger': 'manual',
        'status': 'succeeded',
        'remoteFileId': 'remote-1',
        'remoteFileName': 'papra-backup-abc123.papra-backup',
        'documentsCount': 42,
        'totalSizeBytes': 1048576,
        'processedDocumentsCount': 42,
        'processedBytes': 900000,
        'totalRawBytes': 1048600,
        'uploadedBytes': 1048576,
        'completedAt': '2026-08-01T01:05:00.000Z',
        'createdAt': '2026-08-01T01:00:00.000Z',
      };
      final run = PapraBackupRun.fromJson(json);
      expect(run.status, 'succeeded');
      expect(run.documentsCount, 42);
      expect(run.totalSizeBytes, 1048576);
      expect(run.processedDocumentsCount, 42);
      expect(run.processedBytes, 900000);
      expect(run.totalRawBytes, 1048600);
      expect(run.uploadedBytes, 1048576);
      expect(run.isInProgress, isFalse);
    });

    test('flags in-flight runs for polling', () {
      for (final status in ['pending', 'packaging', 'uploading']) {
        expect(
          PapraBackupRun(id: 'bkrn-x', status: status).isInProgress,
          isTrue,
          reason: status,
        );
      }
      for (final status in ['ready_for_download', 'succeeded', 'failed']) {
        expect(
          PapraBackupRun(id: 'bkrn-x', status: status).isInProgress,
          isFalse,
          reason: status,
        );
      }
    });

    test('parses a restore job', () {
      final json = {
        'id': 'bkrj-1',
        'source': 'run',
        'status': 'restoring',
        'totalDocumentsCount': 42,
        'processedDocumentsCount': 17,
        'downloadedBytes': 512,
        'totalBytes': 1024,
        'restoredDocumentsCount': 10,
        'skippedDuplicatesCount': 2,
        'createdAt': '2026-08-01T01:00:00.000Z',
      };
      final job = PapraBackupRestoreJob.fromJson(json);
      expect(job.source, 'run');
      expect(job.processedDocumentsCount, 17);
      expect(job.totalBytes, 1024);
      expect(job.skippedDuplicatesCount, 2);
    });

    test('parses remote files and verify results', () {
      final file = PapraBackupRemoteFile.fromJson({
        'remoteFileId': '/backups/x.papra-backup',
        'name': 'x.papra-backup',
        'size': 2048,
        'modifiedAt': '2026-08-01T01:00:00.000Z',
      });
      expect(file.name, 'x.papra-backup');
      expect(file.size, 2048);

      final verify = PapraBackupVerifyResult.fromJson({
        'valid': true,
        'totalDocuments': 10,
        'validDocuments': 10,
        'invalidDocuments': 0,
        'errors': [],
      });
      expect(verify.valid, true);
      expect(verify.totalDocuments, 10);
      expect(verify.errors, isEmpty);
    });
  });
}
