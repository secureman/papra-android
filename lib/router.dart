import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/network/models.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/auth_state.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/auth/screens/org_picker_screen.dart';
import 'features/backups/backup_destination_screen.dart';
import 'features/backups/backups_screen.dart';
import 'features/backups/restore_progress_screen.dart';
import 'features/documents/document_detail_screen.dart';
import 'features/documents/documents_screen.dart';
import 'features/documents/pdf_viewer_screen.dart';
import 'features/folders/folders_screen.dart';
import 'features/intake_emails/intake_emails_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/shares/shares_screen.dart';
import 'features/tagging_rules/tagging_rules_screen.dart';
import 'features/tags/tags_screen.dart';
import 'features/tags/tag_documents_screen.dart';
import 'features/trash/trash_screen.dart';
import 'home_shell.dart';
import 'shared/widgets/splash_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authStateProvider);

  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      final location = state.matchedLocation;

      switch (auth) {
        case AuthUnknown():
          return location == '/splash' ? null : '/splash';
        case AuthUnauthenticated():
          return location == '/login' ? null : '/login';
        case AuthNeedsOrgSelection():
          return location == '/orgs' ? null : '/orgs';
        case AuthAuthenticated():
          if (location == '/splash' || location == '/login' || location == '/orgs') {
            return '/';
          }
          return null;
      }
    },
    routes: [
      GoRoute(path: '/splash', builder: (context, state) => const SplashScreen()),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(path: '/orgs', builder: (context, state) => const OrgPickerScreen()),
      GoRoute(
        path: '/shares',
        builder: (context, state) => const SharesScreen(),
      ),
      GoRoute(
        path: '/trash',
        builder: (context, state) => const TrashScreen(),
      ),
      GoRoute(
        path: '/tagging-rules',
        builder: (context, state) => const TaggingRulesScreen(),
      ),
      GoRoute(
        path: '/intake-emails',
        builder: (context, state) => const IntakeEmailsScreen(),
      ),
      GoRoute(
        path: '/backups',
        builder: (context, state) => const BackupsScreen(),
      ),
      GoRoute(
        path: '/backups/destination',
        builder: (context, state) => BackupDestinationScreen(
          destination: state.extra as PapraBackupDestination,
        ),
      ),
      GoRoute(
        path: '/backups/restore/:jobId',
        builder: (context, state) => RestoreProgressScreen(
          jobId: state.pathParameters['jobId'] ?? '',
        ),
      ),
      GoRoute(
        path: '/document/:documentId',
        builder: (context, state) => DocumentDetailScreen(
          documentId: state.pathParameters['documentId'] ?? '',
        ),
      ),
      GoRoute(
        path: '/tag-documents/:tagId',
        builder: (context, state) => TagDocumentsScreen(
          tagId: state.pathParameters['tagId'] ?? '',
          initialTag: state.extra as PapraTag?,
        ),
      ),
      GoRoute(
        // Opens a folder's contents in the Documents browser (used by the
        // Folders tab). Wrapped in its own Scaffold/AppBar so the pushed
        // screen has a back button.
        path: '/documents/folder/:folderId',
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: Text(state.extra as String? ?? 'Folder')),
          body: DocumentsScreen(
            initialFolderId: state.pathParameters['folderId'] ?? '',
            initialFolderName: state.extra as String?,
          ),
        ),
      ),
      GoRoute(
        path: '/document-viewer',
        builder: (context, state) {
          final args = state.extra as ({String filePath, String fileName})?;
          return PdfViewerScreen(
            filePath: args?.filePath ?? '',
            fileName: args?.fileName ?? 'Document',
          );
        },
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => HomeShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/', builder: (context, state) => const DocumentsScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/folders', builder: (context, state) => const FoldersScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/tags', builder: (context, state) => const TagsScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
          ]),
        ],
      ),
    ],
  );
});
