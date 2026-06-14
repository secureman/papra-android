# Papra Android

Lightweight Android client for [Papra](https://papra.app) — focused on uploading documents to your self-hosted or cloud instance.

## Features

- Upload single or multiple files via file picker
- Share files directly into the app from any other app
- Per-file upload progress with retry on failure
- Browse your document list with pull-to-refresh
- API key auth with connection tester
- Works with self-hosted instances (HTTP or HTTPS)

## Stack

- Kotlin + Jetpack Compose
- OkHttp (HTTP / multipart upload)
- DataStore Preferences (settings persistence)
- Navigation Compose (bottom nav)

## Build

1. Open in Android Studio (Hedgehog or newer)
2. Wait for Gradle sync
3. Run on a device/emulator (minSdk 26)

### Release APK

```bash
./gradlew assembleRelease
```

The unsigned APK will be at:
`app/build/outputs/apk/release/app-release-unsigned.apk`

To sign it, set up a keystore and configure `signingConfigs` in `app/build.gradle.kts`.

## Setup in the app

1. Open **Settings** tab
2. Enter your Papra base URL (e.g. `https://papra.app` or `http://192.168.1.10:3000`)
3. Paste your API key (generate one in Papra → Settings → API Keys)
4. Paste your Organization ID (Papra → Settings → Organization)
5. Tap **Test connection** then **Save**

## Notes

- `usesCleartextTraffic="true"` is set so HTTP self-hosted instances work. If you only use HTTPS, you can remove it and the `network_security_config.xml`.
- Document deduplication is handled server-side by Papra (SHA-256 hash). Re-uploading the same file returns HTTP 409, shown as "Document already exists".
