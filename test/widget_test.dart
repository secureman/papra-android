import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:papra_android/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('boots to the login screen when unauthenticated', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const ProviderScope(child: PapraApp()));
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
  });

  testWidgets('prefills server URL and email from saved settings', (tester) async {
    // remember_me is false so startup restore short-circuits to the login
    // screen without touching the network (which is unavailable in tests).
    SharedPreferences.setMockInitialValues({
      'server_url': 'https://docs.example.com',
      'user_email': 'me@example.com',
      'remember_me': false,
    });

    await tester.pumpWidget(const ProviderScope(child: PapraApp()));
    await tester.pumpAndSettle();

    // TextField values render both in EditableText and a sizing Text widget,
    // so assert presence rather than exact count.
    expect(find.text('https://docs.example.com'), findsWidgets);
    expect(find.text('me@example.com'), findsWidgets);
  });
}
