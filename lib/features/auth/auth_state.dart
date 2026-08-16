import '../../core/network/models.dart';

/// The app's auth state machine.
sealed class AuthState {
  const AuthState();
}

/// Restoring a persisted session at startup.
class AuthUnknown extends AuthState {
  const AuthUnknown();
}

/// Not signed in (or session unrecoverable). Shows the login screen.
class AuthUnauthenticated extends AuthState {
  const AuthUnauthenticated();
}

/// Signed in, but the account belongs to multiple organizations and the user
/// hasn't picked one yet.
class AuthNeedsOrgSelection extends AuthState {
  const AuthNeedsOrgSelection({
    required this.baseUrl,
    required this.userEmail,
    required this.organizations,
  });

  final String baseUrl;
  final String userEmail;
  final List<PapraOrganization> organizations;
}

/// Fully signed in with an active organization and a scoped device API key.
class AuthAuthenticated extends AuthState {
  const AuthAuthenticated({
    required this.baseUrl,
    required this.apiKey,
    required this.organizationId,
    required this.organizationName,
    required this.userEmail,
  });

  final String baseUrl;
  final String apiKey;
  final String organizationId;
  final String organizationName;
  final String userEmail;
}
