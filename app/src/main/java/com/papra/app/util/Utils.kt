package com.papra.app.util

import android.content.Context

/**
 * Unified default tag color. Used in both DocumentsScreen and UploadScreen/CreateTagDialog
 * to eliminate the #3B82F6 vs #2563EB inconsistency (FIX #15).
 */
const val DEFAULT_TAG_COLOR = "#3B82F6"

/**
 * FIX #4: Delete all papra_* temp files from cacheDir.
 *
 * downloadDocumentToCache() names every file "papra_<documentId>_<name>", so this
 * prefix match is safe — it won't touch unrelated cache entries from other libraries.
 *
 * Called from MainActivity.onCreate() to clear stale files from previous sessions.
 */
fun cleanPapraCache(context: Context) {
    try {
        context.cacheDir
            .listFiles { file -> file.name.startsWith("papra_") }
            ?.forEach { it.delete() }
    } catch (_: Exception) {
        // Swallow — cache cleanup is best-effort; never crash the app over it.
    }
}
