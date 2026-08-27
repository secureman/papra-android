import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papra_android/core/network/api_client.dart';
import 'package:papra_android/core/network/api_exception.dart';
import 'package:papra_android/core/network/models.dart';
import 'package:papra_android/core/network/session_cookie_store.dart';
import 'package:papra_android/core/storage/secure_store.dart';
import 'package:papra_android/features/auth/auth_controller.dart';
import 'package:papra_android/features/backups/backup_destination_screen.dart';
import 'package:papra_android/features/backups/backups_ui.dart';

/// In-memory [ApiClient] stub for the backup destination detail screen.
class _FakeApiClient extends ApiClient {
  _FakeApiClient()
      : super(
          baseUrl: 'https://example.com',
          organizationId: 'org-1',
          apiKey: 'key',
          cookieStore: SessionCookieStore(SecureStore()),
          onAuthFailure: () {},
        );

  List<PapraBackupRun> runs = [];

  int listRunsCalls = 0;
  int runNowCalls = 0;
  int connectCalls = 0;
  int claimCalls = 0;
  String connectUrl = 'https://accounts.google.com/o/oauth2/v2/auth?state=abc';
  String? runNowError;

  @override
  Future<List<PapraBackupRun>> listBackupRuns(String destinationId) async {
    listRunsCalls++;
    return runs;
  }

  @override
  Future<String> runBackup(String destinationId) async {
    runNowCalls++;
    if (runNowError != null) throw PapraApiException(message: runNowError!);
    return 'bkrn-new';
  }

  @override
  Future<String> getGoogleDriveConnectUrl({String displayName = 'Google Drive'}) async {
    connectCalls++;
    return connectUrl;
  }

  @override
  Future<void> downloadReadyBackupRun({
    required String destinationId,
    required String runId,
    required String savePath,
    void Function(int received, int total)? onReceiveProgress,
  }) async {
    claimCalls++;
  }
}

PapraBackupDestination _destination({String driver = 'google_drive'}) => PapraBackupDestination(
      id: 'bkdst-1',
      driver: driver,
      displayName: driver == 'google_drive' ? 'Gdrive' : 'NAS',
      accountLabel: 'hicham@example.com',
      createdAt: '2026-08-01T00:00:00.000Z',
    );

PapraBackupRun _run({
  String id = 'bkrn-1',
  String status = 'succeeded',
  String? errorMessage,
  String trigger = 'manual',
  int? documentsCount,
  int? totalSizeBytes,
  int processedDocumentsCount = 0,
  int? processedBytes,
  int? totalRawBytes,
  int? uploadedBytes,
  String? remoteFileId,
  String? remoteFileName,
}) =>
    PapraBackupRun(
      id: id,
      trigger: trigger,
      status: status,
      errorMessage: errorMessage,
      documentsCount: documentsCount,
      totalSizeBytes: totalSizeBytes,
      processedDocumentsCount: processedDocumentsCount,
      processedBytes: processedBytes,
      totalRawBytes: totalRawBytes,
      uploadedBytes: uploadedBytes,
      remoteFileId: remoteFileId,
      remoteFileName: remoteFileName,
      createdAt: '2026-08-01T01:00:00.000Z',
    );

Future<void> _pump(WidgetTester tester, _FakeApiClient client,
    {PapraBackupDestination? destination}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp(
        home: BackupDestinationScreen(destination: destination ?? _destination()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Lets the snackbar auto-dismiss timer fire so no timers are left pending.
Future<void> _flushSnackbar(WidgetTester tester) async {
  await tester.pumpAndSettle(const Duration(seconds: 5));
}

Widget _app(_FakeApiClient client, {PapraBackupDestination? destination}) =>
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp(
        home: BackupDestinationScreen(destination: destination ?? _destination()),
      ),
    );

void main() {
  testWidgets('shows the empty run history with a run-now button', (tester) async {
    final client = _FakeApiClient();
    await _pump(tester, client);

    expect(find.text('Gdrive'), findsOneWidget);
    expect(find.text('Run backup now'), findsOneWidget);
    expect(find.textContaining('No runs yet'), findsOneWidget);
  });

  testWidgets('lists runs with status, trigger and document counts', (tester) async {
    final client = _FakeApiClient()
      ..runs = [
        _run(documentsCount: 12, remoteFileId: 'remote-1'),
        _run(
          id: 'bkrn-2',
          status: 'failed',
          errorMessage: 'Disk full',
          documentsCount: 0,
        ),
      ];
    await _pump(tester, client);

    expect(find.textContaining('Manual backup'), findsNWidgets(2));
    expect(find.textContaining('Succeeded'), findsOneWidget);
    expect(find.textContaining('12 documents'), findsOneWidget);
    expect(find.textContaining('Failed'), findsOneWidget);
    expect(find.text('Disk full'), findsOneWidget);
  });

  testWidgets('shows a reconnect affordance on OAuth authorization failures',
      (tester) async {
    final client = _FakeApiClient()
      ..runs = [
        _run(
          id: 'bkrn-1',
          status: 'failed',
          errorMessage:
              'Google Drive OAuth failed (400): invalid_grant — Token has been expired or revoked. '
              'Reconnect the destination from the web app.',
        ),
      ];
    await _pump(tester, client);

    expect(find.textContaining('expired or revoked'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Reconnect'), findsOneWidget);
  });

  testWidgets('does not show a reconnect affordance for non-OAuth failures',
      (tester) async {
    final client = _FakeApiClient()
      ..runs = [
        _run(id: 'bkrn-1', status: 'failed', errorMessage: 'Disk full'),
      ];
    await _pump(tester, client);

    expect(find.text('Disk full'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Reconnect'), findsNothing);
  });

  testWidgets('google_drive destinations get a reconnect menu item', (tester) async {
    final gdClient = _FakeApiClient();
    await _pump(tester, gdClient, destination: _destination(driver: 'google_drive'));
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Reconnect Google Drive'), findsOneWidget);
  });

  testWidgets('non-google-drive destinations do not get a reconnect menu item',
      (tester) async {
    final webdavClient = _FakeApiClient();
    await _pump(tester, webdavClient, destination: _destination(driver: 'webdav'));
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Reconnect Google Drive'), findsNothing);
  });

  testWidgets('tapping Run backup now triggers the run and refreshes history',
      (tester) async {
    final client = _FakeApiClient();
    await _pump(tester, client);

    await tester.tap(find.text('Run backup now'));
    await tester.pumpAndSettle();

    expect(client.runNowCalls, 1);
    expect(find.textContaining('Backup started'), findsOneWidget);
    await _flushSnackbar(tester);
  });

  testWidgets('shows the server error when run now fails', (tester) async {
    final client = _FakeApiClient()..runNowError = 'A backup is already in progress for this destination';
    await _pump(tester, client);

    await tester.tap(find.text('Run backup now'));
    await tester.pumpAndSettle();

    expect(find.textContaining('already in progress'), findsOneWidget);
    await _flushSnackbar(tester);
  });

  testWidgets('tapping Reconnect opens the OAuth authorization URL', (tester) async {
    final client = _FakeApiClient()
      ..connectUrl = 'https://accounts.google.com/o/oauth2/v2/auth?state=xyz'
      ..runs = [
        _run(
          id: 'bkrn-1',
          status: 'failed',
          errorMessage: 'Google Drive OAuth failed (400): invalid_grant',
        ),
      ];
    final launches = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (call) async {
        if (call.method == 'launch') {
          launches.add((call.arguments as Map)['url'] as String);
          return true;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), null);
    });

    await _pump(tester, client);
    await tester.tap(find.widgetWithText(TextButton, 'Reconnect'));
    await tester.pumpAndSettle();

    expect(client.connectCalls, 1);
    expect(launches, ['https://accounts.google.com/o/oauth2/v2/auth?state=xyz']);
  });

  group('real run progress', () {
    testWidgets('packaging runs show a real byte/document progress bar', (tester) async {
      final client = _FakeApiClient()
        ..runs = [
          _run(
            status: 'packaging',
            documentsCount: 40,
            processedDocumentsCount: 20,
            processedBytes: 512,
            totalRawBytes: 1024,
            totalSizeBytes: null,
          ),
        ];
      await tester.pumpWidget(_app(client));
      await tester.pump();
      await tester.pump();

      final progress = describeRunProgress(client.runs.single);
      expect(progress.percent, closeTo(0.5, 0.001));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        find.textContaining('Packaging… 512 B / 1.0 KB'),
        findsOneWidget,
      );
    });

    testWidgets('uploading runs show uploaded bytes out of the envelope size',
        (tester) async {
      final client = _FakeApiClient()
        ..runs = [
          _run(status: 'uploading', totalSizeBytes: 2000, uploadedBytes: 1000),
        ];
      await tester.pumpWidget(_app(client));
      await tester.pump();
      await tester.pump();

      final progress = describeRunProgress(client.runs.single);
      expect(progress.percent, closeTo(0.5, 0.001));
      expect(find.textContaining('Uploading…'), findsOneWidget);
    });

    testWidgets('keeps polling while a run is in flight and stops when done',
        (tester) async {
      final client = _FakeApiClient()
        ..runs = [
          _run(status: 'uploading', totalSizeBytes: 2000, uploadedBytes: 100),
        ];
      await tester.pumpWidget(_app(client));
      await tester.pump();
      await tester.pump();
      expect(client.listRunsCalls, 1);

      // First tick: still in progress → refreshes again.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(client.listRunsCalls, greaterThanOrEqualTo(2));

      // Run finished server-side → polling stops.
      client.runs = [_run(status: 'succeeded', remoteFileId: 'remote-1')];
      while (client.listRunsCalls < 3) {
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
      }
      final callsAfterTerminal = client.listRunsCalls;
      await tester.pump(const Duration(seconds: 5));
      expect(client.listRunsCalls, callsAfterTerminal);

      // Unmount so the disposed state cancels any stray timers.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    });
  });

  group('local delivery (ready_for_download)', () {
    PapraBackupRun readyRun({String id = 'bkrn-ready'}) => _run(
          id: id,
          status: 'ready_for_download',
          documentsCount: 7,
          remoteFileName: 'papra-backup-local.papra-backup',
        );

    testWidgets('local destinations offer “Save to device” for ready runs',
        (tester) async {
      final client = _FakeApiClient()..runs = [readyRun()];
      await tester.pumpWidget(_app(client, destination: _destination(driver: 'local')));
      await tester.pump();
      await tester.pump();

      // The automatic claim attempt fails silently in the test environment
      // (no folder picker) and backs off — the manual action remains.
      expect(find.textContaining('Saving to your device'), findsOneWidget);

      await tester.tap(find.byType(PopupMenuButton<String>).last);
      await tester.pump();
      expect(find.text('Save to device'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('non-local destinations never show the save action',
        (tester) async {
      final client = _FakeApiClient()
        ..runs = [_run(status: 'ready_for_download')];
      await tester.pumpWidget(_app(client));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byType(PopupMenuButton<String>).last);
      await tester.pump();
      expect(find.text('Save to device'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    });
  });
}