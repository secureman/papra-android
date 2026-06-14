package com.papra.app.data.api

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okio.BufferedSink
import okio.source
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

sealed class ApiResult<out T> {
    data class Success<T>(val data: T) : ApiResult<T>()
    data class Error(val code: Int, val message: String) : ApiResult<Nothing>()
    data class NetworkError(val message: String) : ApiResult<Nothing>()
}

data class PapraDocument(
    val id: String,
    val name: String,
    val createdAt: String,
    val size: Long
)

class PapraApiClient(private val context: Context) {

    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .build()

    // ── Connection test ──────────────────────────────────────────────────────

    suspend fun testConnection(baseUrl: String, apiKey: String): ApiResult<Unit> =
        withContext(Dispatchers.IO) {
            try {
                val request = Request.Builder()
                    .url("$baseUrl/api/organizations")
                    .header("Authorization", "Bearer $apiKey")
                    .get()
                    .build()

                client.newCall(request).execute().use { response ->
                    when {
                        response.isSuccessful -> ApiResult.Success(Unit)
                        response.code == 401 -> ApiResult.Error(401, "Invalid API key")
                        else -> ApiResult.Error(response.code, "HTTP ${response.code}")
                    }
                }
            } catch (e: IOException) {
                ApiResult.NetworkError(e.message ?: "Network error")
            }
        }

    // ── Upload document ──────────────────────────────────────────────────────

    suspend fun uploadDocument(
        baseUrl: String,
        apiKey: String,
        organizationId: String,
        uri: Uri,
        onProgress: (Int) -> Unit = {}
    ): ApiResult<Unit> = withContext(Dispatchers.IO) {
        try {
            val fileName = resolveFileName(uri)
            val mimeType = context.contentResolver.getType(uri) ?: "application/octet-stream"
            val fileSize = resolveFileSize(uri)

            val requestBody = object : RequestBody() {
                override fun contentType() = mimeType.toMediaTypeOrNull()
                override fun contentLength() = fileSize

                override fun writeTo(sink: BufferedSink) {
                    val inputStream = context.contentResolver.openInputStream(uri)
                        ?: throw IOException("Cannot open URI: $uri")
                    var bytesWritten = 0L
                    inputStream.source().use { source ->
                        val buffer = okio.Buffer()
                        var bytesRead: Long
                        while (source.read(buffer, 8192L).also { bytesRead = it } != -1L) {
                            sink.write(buffer, bytesRead)
                            bytesWritten += bytesRead
                            if (fileSize > 0) {
                                onProgress((bytesWritten * 100 / fileSize).toInt())
                            }
                        }
                    }
                }
            }

            val multipart = MultipartBody.Builder()
                .setType(MultipartBody.FORM)
                .addFormDataPart("file", fileName, requestBody)
                .build()

            val request = Request.Builder()
                .url("$baseUrl/api/organizations/$organizationId/documents")
                .header("Authorization", "Bearer $apiKey")
                .post(multipart)
                .build()

            client.newCall(request).execute().use { response ->
                when {
                    response.isSuccessful -> {
                        onProgress(100)
                        ApiResult.Success(Unit)
                    }
                    response.code == 401 -> ApiResult.Error(401, "Invalid API key")
                    response.code == 409 -> ApiResult.Error(409, "Document already exists")
                    else -> ApiResult.Error(response.code, "Upload failed: HTTP ${response.code}")
                }
            }
        } catch (e: IOException) {
            ApiResult.NetworkError(e.message ?: "Network error")
        }
    }

    // ── List documents ───────────────────────────────────────────────────────

    suspend fun listDocuments(
        baseUrl: String,
        apiKey: String,
        organizationId: String
    ): ApiResult<List<PapraDocument>> = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder()
                .url("$baseUrl/api/organizations/$organizationId/documents")
                .header("Authorization", "Bearer $apiKey")
                .get()
                .build()

            client.newCall(request).execute().use { response ->
                when {
                    response.isSuccessful -> {
                        val body = response.body?.string() ?: "[]"
                        val docs = parseDocuments(body)
                        ApiResult.Success(docs)
                    }
                    response.code == 401 -> ApiResult.Error(401, "Invalid API key")
                    else -> ApiResult.Error(response.code, "HTTP ${response.code}")
                }
            }
        } catch (e: IOException) {
            ApiResult.NetworkError(e.message ?: "Network error")
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private fun resolveFileName(uri: Uri): String {
        var name = "document"
        context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (cursor.moveToFirst() && nameIndex >= 0) {
                name = cursor.getString(nameIndex)
            }
        }
        return name
    }

    private fun resolveFileSize(uri: Uri): Long {
        context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (cursor.moveToFirst() && sizeIndex >= 0) {
                return cursor.getLong(sizeIndex)
            }
        }
        return -1L
    }

    private fun parseDocuments(json: String): List<PapraDocument> {
        return try {
            val root = JSONObject(json)
            // Papra returns { documents: [...] }
            val array = root.optJSONArray("documents") ?: return emptyList()
            (0 until array.length()).map { i ->
                val obj = array.getJSONObject(i)
                PapraDocument(
                    id = obj.optString("id", ""),
                    name = obj.optString("name", "Untitled"),
                    createdAt = obj.optString("createdAt", ""),
                    size = obj.optLong("fileSize", 0L)
                )
            }
        } catch (e: Exception) {
            emptyList()
        }
    }
}
