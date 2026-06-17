package com.papra.app.util

import android.content.Context

/**
 * Unified default tag color. Used in both DocumentsScreen and UploadScreen/CreateTagDialog
 * to eliminate the #3B82F6 vs #2563EB inconsistency (FIX #15).
 */
const val DEFAULT_TAG_COLOR = "#3B82F6"

/** Default cap for the papra_* cache, in bytes. 50 MB covers ~100 typical docs comfortably. */
private const val DEFAULT_CACHE_CAP_BYTES = 50L * 1024L * 1024L

/**
 * Trim papra_* files in cacheDir so that their total size stays ≤ [maxBytes].
 *
 * Replaces the previous `cleanPapraCache()`, which ran unconditionally on every
 * MainActivity.onCreate() (i.e. on every rotation, theme change, font-scale change,
 * process restart…) and deleted the file out from under the viewer, producing
 * "Cannot open this PDF" / "Failed to load image" / "Failed to open document" errors.
 *
 * Semantics:
 * - No-op when total size is already under the cap (the common case).
 * - Otherwise, delete oldest files first (by lastModified), keeping recently-opened
 *   documents cached so the viewer can be re-entered cheaply.
 * - Safe to invoke after every successful download — overhead is a single directory
 *   listing + sum, both cheap for tens of files.
 * - Best-effort: never throws. A failure here must never break the open-doc flow.
 */
fun trimPapraCache(context: Context, maxBytes: Long = DEFAULT_CACHE_CAP_BYTES) {
    try {
        val files = context.cacheDir
            .listFiles { f -> f.isFile && f.name.startsWith("papra_") }
            ?: return

        var total = files.sumOf { it.length() }
        if (total <= maxBytes) return

        // Oldest first — least recently accessed gets evicted.
        val sorted = files.sortedBy { it.lastModified() }
        for (f in sorted) {
            if (total <= maxBytes) break
            val size = f.length()
            if (f.delete()) total -= size
        }
    } catch (_: Exception) {
        // Best-effort — never crash the app over cache housekeeping.
    }
}