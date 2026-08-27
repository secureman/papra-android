import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:papra_android/features/offline/offline_models.dart';
import 'package:papra_android/features/offline/offline_providers.dart';
import 'package:papra_android/features/offline/offline_snapshot_store.dart';
import 'package:papra_android/features/offline/screens/offline_documents_view.dart';
import 'package:papra_android/features/offline/screens/offline_folders_view.dart';
import 'package:papra_android/features/offline/screens/offline_tags_view.dart';

/// Store stub — the real one touches the filesystem, which hangs in the
/// fake-async widget-test zone (same reason screen tests stub DocumentCache).
/// Null snapshot dir means tiles render without thumbnails and skip I/O.
class _FakeStore extends OfflineSnapshotStore {
  @override
  Future<String?> snapshotPath() async => null;
}

OfflineDocument _doc({
  required String id,
  required String name,
  List<String> folderPath = const [],
  List<OfflineTagRef> tags = const [],
  String createdAt = '2026-01-01T00:00:00.000Z',
}) {
  return OfflineDocument(
    id: id,
    name: name,
    originalName: name,
    mimeType: 'application/octet-stream',
    size: 1024,
    createdAt: createdAt,
    folderPath: folderPath,
    tags: tags,
  );
}

Future<void> _pumpView(
  WidgetTester tester,
  Widget Function(List<OfflineDocument>) buildView,
  List<OfflineDocument> documents,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        offlineSnapshotStoreProvider.overrideWithValue(_FakeStore()),
      ],
      child: MaterialApp(home: Scaffold(body: buildView(documents))),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OfflineDocumentsView', () {
    final documents = [
      _doc(id: 'd-1', name: 'Invoice January'),
      _doc(
        id: 'd-2',
        name: 'Contract',
        folderPath: ['Legal'],
        tags: [const OfflineTagRef(name: 'signed', color: '#43a047')],
      ),
      _doc(id: 'd-3', name: 'Notes', folderPath: ['Legal', '2026']),
    ];

    testWidgets('lists root documents and subfolders', (tester) async {
      await _pumpView(tester, (docs) => OfflineDocumentsView(documents: docs), documents);

      expect(find.text('Invoice January'), findsOneWidget);
      expect(find.text('Legal'), findsOneWidget); // subfolder row
      expect(find.text('Contract'), findsNothing); // inside Legal
    });

    testWidgets('entering a folder filters by breadcrumb prefix', (tester) async {
      await _pumpView(tester, (docs) => OfflineDocumentsView(documents: docs), documents);

      await tester.tap(find.text('Legal'));
      await tester.pumpAndSettle();

      expect(find.text('Contract'), findsOneWidget);
      expect(find.text('2026'), findsOneWidget); // nested subfolder row
      expect(find.text('Invoice January'), findsNothing);

      // Breadcrumb back to root.
      await tester.tap(find.text('All documents'));
      await tester.pumpAndSettle();
      expect(find.text('Invoice January'), findsOneWidget);
    });

    testWidgets('search filters across name, tags and folder paths', (tester) async {
      await _pumpView(tester, (docs) => OfflineDocumentsView(documents: docs), documents);

      await tester.enterText(find.byType(TextField), 'signed');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('Contract'), findsOneWidget);
      expect(find.text('Invoice January'), findsNothing);
    });

    testWidgets('shows empty state for no matches', (tester) async {
      await _pumpView(tester, (docs) => OfflineDocumentsView(documents: docs), documents);

      await tester.enterText(find.byType(TextField), 'zzz-nothing');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('No results'), findsOneWidget);
    });
  });

  group('OfflineTagsView', () {
    testWidgets('aggregates duplicate tag names with counts', (tester) async {
      final documents = [
        _doc(id: 'a', name: 'A', tags: [const OfflineTagRef(name: 'invoice', color: '#1e88e5')]),
        _doc(id: 'b', name: 'B', tags: [const OfflineTagRef(name: 'Invoice', color: '#1e88e5')]),
        _doc(id: 'c', name: 'C'),
      ];

      await _pumpView(tester, (docs) => OfflineTagsView(documents: docs), documents);

      expect(find.text('invoice'), findsOneWidget); // deduped case-insensitively
      expect(find.text('2 documents'), findsOneWidget);
    });

    testWidgets('empty snapshot shows placeholder', (tester) async {
      await _pumpView(tester, (docs) => OfflineTagsView(documents: docs), [_doc(id: 'x', name: 'X')]);

      expect(find.text('No tags'), findsOneWidget);
    });
  });

  group('OfflineFoldersView', () {
    testWidgets('builds a tree with recursive counts', (tester) async {
      final documents = [
        _doc(id: 'root', name: 'Root doc'),
        _doc(id: 'f1', name: 'F1 doc', folderPath: ['Finance']),
        _doc(id: 'f2', name: 'F2 doc', folderPath: ['Finance', '2026']),
      ];

      await _pumpView(tester, (docs) => OfflineFoldersView(documents: docs), documents);

      expect(find.text('Root (no folder)'), findsOneWidget);
      expect(find.text('Finance'), findsOneWidget);
      // Finance subtree total = direct 1 + child 1.
      expect(find.text('2 documents'), findsOneWidget);
    });

    testWidgets('expanding a folder reveals its files inline', (tester) async {
      final documents = [
        _doc(id: 'f1', name: 'F1 doc', folderPath: ['Finance']),
        _doc(id: 'f2', name: 'F2 doc', folderPath: ['Finance', '2026']),
        _doc(id: 'other', name: 'Other', folderPath: ['HR']),
      ];

      await _pumpView(tester, (docs) => OfflineFoldersView(documents: docs), documents);

      // Collapsed by default: no document rows visible.
      expect(find.text('F1 doc'), findsNothing);

      // Tap Finance once: its own document appears immediately.
      await tester.tap(find.text('Finance'));
      await tester.pumpAndSettle();
      expect(find.text('F1 doc'), findsOneWidget);
      expect(find.text('Other'), findsNothing);
      // Nested subfolder is listed too.
      expect(find.text('2026'), findsOneWidget);

      // Expand the nested folder as well.
      await tester.tap(find.text('2026'));
      await tester.pumpAndSettle();
      expect(find.text('F2 doc'), findsOneWidget);

      // Tapping again collapses.
      await tester.tap(find.text('2026'));
      await tester.pumpAndSettle();
      expect(find.text('F2 doc'), findsNothing);
    });

    testWidgets('root row expands to show root-level documents', (tester) async {
      final documents = [
        _doc(id: 'root', name: 'Root doc'),
        _doc(id: 'nested', name: 'Nested doc', folderPath: ['HR']),
      ];

      await _pumpView(tester, (docs) => OfflineFoldersView(documents: docs), documents);

      expect(find.text('Root doc'), findsNothing);
      await tester.tap(find.text('Root (no folder)'));
      await tester.pumpAndSettle();
      expect(find.text('Root doc'), findsOneWidget);
      expect(find.text('Nested doc'), findsNothing); // belongs to HR
    });
  });
}
