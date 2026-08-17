# papra-android (fork client)

Android client for the [secureman/papra](https://github.com/secureman/papra) fork.

This branch (`fork-client`) is the client for the user's fork of Papra. The
official app for [papra-hq/papra](https://github.com/papra-hq/papra) lives on
the `main` branch.

## Features

- Sign in with email/password to your self-hosted Papra server (Better Auth).
- "Stay signed in" is on by default — the session is restored on launch.
- Document archive: browse, search, preview (PDF), pin for offline, trash.
- Folders, tags, custom properties, shares, intake emails and tagging rules.
- One-tap backups (S3/WebDAV/etc. drivers) with restore progress.
- Multi-organization accounts with per-org device API keys.
- Optional Origin/Referer headers for servers with strict CORS checks.

## Build

```sh
flutter pub get
flutter run                # debug
flutter build apk          # release (uses key.properties or CI secrets)
```

Release signing comes from `key.properties` (local, gitignored) or the
`RELEASE_KEYSTORE_*` environment variables; it falls back to the debug
keystore when neither is present.

## Tests

```sh
flutter test
```
