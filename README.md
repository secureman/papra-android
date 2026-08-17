<div align="center">

# Papra — Android client

The Android app for [Papra](https://github.com/papra-hq/papra), the minimalistic
self-hosted document management and archiving platform.

Store, search, and retrieve your documents from your Android device — connected
to your own Papra server.

</div>

## Features

- **Email/password sign-in** against your self-hosted Papra server (Better Auth).
- **Stays signed in** — your session is restored automatically on launch.
- **Multi-organization support** with a dedicated, per-org device API key.
- **Document archive** — browse, full-text search, and sort your documents.
- **PDF preview** built in, plus "open original" in any external app.
- **Offline-first** — document lists and previews render from an on-device cache
  even without a connection.
- **Pin for offline** — mark individual originals as available offline
  (Google-Drive style).
- **Trash** — restore or permanently delete documents.
- **Tags & custom properties** to organize documents the way you want.
- **Shares** — create and manage public document share links.
- **Intake emails** — view and manage your account's email ingestion.
- **Tagging rules** — create, edit, and apply automatic tagging rules.
- **Dark mode** — system, light, or dark theme.
- **Strict-CORS friendly** — optional `Origin`/`Referer` headers for servers
  that reject cross-origin requests.

## Requirements

- Flutter 3.44+ (Dart SDK `^3.12.2`)
- An Android device or emulator (Android 7.0+, minSdk 24)
- A self-hosted Papra server. See the
  [self-hosting guide](https://docs.papra.app) — quick start:

  ```sh
  docker run -d --name papra -p 1221:1221 \
    -e AUTH_SECRET=a-dummy-secret-for-testing-purposes-only \
    ghcr.io/papra-hq/papra:latest
  ```

## Getting started

```sh
git clone https://github.com/secureman/papra-android.git
cd papra-android
flutter pub get
flutter run
```

On first launch, enter your Papra server URL (e.g. `https://docs.example.com`)
and your account credentials. If your account belongs to several organizations,
pick one — the app mints a scoped device API key for it and stores it securely.

## Building a release APK

By default the release build signs with the **debug keystore**, which is fine
for personal use but not for distribution. To sign properly, add a signing
config to `android/app/build.gradle.kts` (see the `signingConfigs` block) or
point the release `signingConfig` at your own keystore, then:

```sh
flutter build apk --release
```

The APK will be written to `build/app/outputs/flutter-apk/`.

## Tests

```sh
flutter test
```

## Branches

- `main` — this client for the official [papra-hq/papra](https://github.com/papra-hq/papra) server.
- `fork-client` — a client for a [community fork](https://github.com/secureman/papra) with extra features (folders, backups).

## Related

- [Papra server](https://github.com/papra-hq/papra) — the platform itself
- [Papra docs](https://docs.papra.app)
- [Demo instance](https://demo.papra.app)

## License

AGPL-3.0, the same license as the upstream Papra project. The repository does
not ship a `LICENSE` file yet; see the
[upstream license](https://github.com/papra-hq/papra/blob/main/LICENSE).
