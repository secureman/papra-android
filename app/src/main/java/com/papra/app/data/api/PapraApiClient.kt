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
import okhttp3.RequestBody.Companion.toRequestBody
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
    val size: Long,
    val mimeType: String = "",
    val tags: List<PapraTag> = emptyList()
)

data class PapraTag(
    val id: String,
    val name: String,
    val color: String = ""
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
                    .get().build()
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
    ): ApiResult<String> = withContext(Dispatchers.IO) {
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
                            if (fileSize > 0) onProgress((bytesWritten * 100 / fileSize).toInt())
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
                .post(multipart).build()

            client.newCall(request).execute().use { response ->
                when {
                    response.isSuccessful -> {
                        onProgress(100)
                        val body = response.body?.string() ?: "{}"
                        val docId = try {
                            JSONObject(body).optJSONObject("document")?.optString("id") ?: ""
                        } catch (e: Exception) { "" }
                        ApiResult.Success(docId)
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
        organizationId: String,
        search: String = ""
    ): ApiResult<List<PapraDocument>> = withContext(Dispatchers.IO) {
        try {
            val url = buildString {
                append("$baseUrl/api/organizations/$organizationId/documents")
                if (search.isNotBlank()) append("?searchQuery=${Uri.encode(search)}")
            }
            val request = Request.Builder()
                .url(url)
                .header("Authorization", "Bearer $apiKey")
                .get().build()

            client.newCall(request).execute().use { response ->
                when {
                    response.isSuccessful -> ApiResult.Success(parseDocuments(response.body?.string() ?: "{}"))
                    response.code == 401 -> ApiResult.Error(401, "Invalid API key")
                    else -> ApiResult.Error(response.code, "HTTP ${response.code}")
                }
            }
        } catch (e: IOException) {
            ApiResult.NetworkError(e.message ?: "Network error")
        }
    }

    // ── Get document file bytes (for viewing/thumbnails) ─────────────────────

    suspend fun getDocumentFileUrl(
        baseUrl: String,
        apiKey: String,
        organizationId: String,
        documentId: String
    ): String = "$baseUrl/api/organizations/$organizationId/documents/$documentId/file"

    suspend fun downloadDocumentToCache(
        baseUrl: String,
        apiKey: String,
        organizationId: String,
        documentId: String,
        fileName: String
    ): ApiResult<java.io.File> = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder()
                .url("$baseUrl/api/organizations/$organizationId/documents/$documentId/file")
                .header("Authorization", "Bearer $apiKey")
                .get().build()

            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@withContext ApiResult.Error(response.code, "HTTP ${response.code}")
                val cacheFile = java.io.File(context.cacheDir, "papra_$documentId${fileExtension(fileName)}")
                response.body?.byteStream()?.use { input ->
                    cacheFile.outputStream().use { output -> input.copyTo(output) }
                }
                ApiResult.Success(cacheFile)
            }
        } catch (e: IOException) {
            ApiResult.NetworkError(e.message ?: "Network error")
        }
    }

    // ── Delete document ──────────────────────────────────────────────────────

    suspend fun deleteDocument(
        baseUrl: String,
        apiKey: String,
        organizationId: String,
        documentId: String
    ): ApiResult<Unit> = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder()
                .url("$baseUrl/api/organizations/$organizationId/documents/$documentId")
                .header("Authorization", "Bearer $apiKey")
                .delete().build()
            client.newCall(request).execute().use { response ->
                if (response.isSuccessful) ApiResult.Success(Unit)
                else ApiResult.Error(response.code, "HTTP ${response.code}")
            }
        } catch (e: IOException) {
            ApiResult.NetworkError(e.message ?: "Network error")
        }
    }

    // ── Tags ─────────────────────────────────────────────────────────────────

    suspend fun listTags(
        baseUrl: String,
        apiKey: String,
        organizationId: String
    ): ApiResult<List<PapraTag>> = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder()
                .url("$baseUrl/api/organizations/$organizationId/tags")
                .header("Authorization", "Bearer $apiKey")
                .get().build()
            client.newCall(request).execute().use { response ->
                if (response.isSuccessful) ApiResult.Success(parseTags(response.body?.string() ?: "{}"))
                else ApiResult.Error(response.code, "HTTP ${response.code}")
            }
        } catch (e: IOException) {
            ApiResult.NetworkError(e.message ?: "Network error")
        }
    }

    suspend fun createTag(
        baseUrl: String,
        apiKey: String,
        organizationId: String,
        name: String,
        color: String
    ): ApiResult<PapraTag> = withContext(Dispatchers.IO) {
        try {
            val body = MultipartBody.Builder()
                .setType(MultipartBody.FORM)
                .addFormDataPart("name", name)
                .addFormDataPart("color", color)
                .build()
            val request = Request.Builder()
                .url("$baseUrl/api/organizations/$organizationId/tags")
                .header("Authorization", "Bearer $apiKey")
                .post(body).build()
            client.newCall(request).execute().use { response ->
                if (response.isSuccessful) {
                    val obj = JSONObject(response.body?.string() ?: "{}").optJSONObject("tag")
                    val tag = PapraTag(
                        id = obj?.optString("id") ?: "",
                        name = obj?.optString("name") ?: name,
                        color = obj?.optString("color") ?: color
                    )
                    ApiResult.Success(tag)
                } else ApiResult.Error(response.code, "HTTP ${response.code}")
            }
        } catch (e: IOException) {
            ApiResult.NetworkError(e.message ?: "Network error")
        }
    }

    suspend fun addTagToDocument(
        baseUrl: String,
        apiKey: String,
        organizationId: String,
        documentId: String,
        tagId: String
    ): ApiResult<Unit> = withContext(Dispatchers.IO) {
        try {
            val body = JSONObject().put("tagId", tagId).toString()
                .toRequestBody("application/json".toMediaTypeOrNull())
            val request = Request.Builder()
                .url("$baseUrl/api/organizations/$organizationId/documents/$documentId/tags")
                .header("Authorization", "Bearer $apiKey")
                .post(body).build()
            client.newCall(request).execute().use { response ->
                if (response.isSuccessful) ApiResult.Success(Unit)
                else ApiResult.Error(response.code, "HTTP ${response.code}")
            }
        } catch (e: IOException) {
            ApiResult.NetworkError(e.message ?: "Network error")
        }
    }

    suspend fun renameDocument(
        baseUrl: String,
        apiKey: String,
        organizationId: String,
        documentId: String,
        newName: String
    ): ApiResult<Unit> = withContext(Dispatchers.IO) {
        try {
            val body = MultipartBody.Builder()
                .setType(MultipartBody.FORM)
                .addFormDataPart("name", newName)
                .build()
            val request = Request.Builder()
                .url("$baseUrl/api/organizations/$organizationId/documents/$documentId")
                .header("Authorization", "Bearer $apiKey")
                .patch(body).build()
            client.newCall(request).execute().use { response ->
                if (response.isSuccessful) ApiResult.Success(Unit)
                else ApiResult.Error(response.code, "HTTP ${response.code}")
            }
        } catch (e: IOException) {
            ApiResult.NetworkError(e.message ?: "Network error")
        }
    }

    suspend fun removeTagFromDocument(
        baseUrl: String,
        apiKey: String,
        organizationId: String,
        documentId: String,
        tagId: String
    ): ApiResult<Unit> = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder()
                .url("$baseUrl/api/organizations/$organizationId/documents/$documentId/tags/$tagId")
                .header("Authorization", "Bearer $apiKey")
                .delete().build()
            client.newCall(request).execute().use { response ->
                if (response.isSuccessful) ApiResult.Success(Unit)
                else ApiResult.Error(response.code, "HTTP ${response.code}")
            }
        } catch (e: IOException) {
            ApiResult.NetworkError(e.message ?: "Network error")
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    fun resolveFileName(uri: Uri): String {
        var name = uri.lastPathSegment ?: "document"
        context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val col = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (cursor.moveToFirst() && col >= 0) name = cursor.getString(col)
        }
        return name
    }

    fun resolveFileSize(uri: Uri): Long {
        context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val col = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (cursor.moveToFirst() && col >= 0) return cursor.getLong(col)
        }
        return -1L
    }

    private fun fileExtension(name: String): String {
        val dot = name.lastIndexOf('.')
        return if (dot >= 0) name.substring(dot) else ""
    }

    private fun parseDocuments(json: String): List<PapraDocument> {
        return try {
            val root = JSONObject(json)
            val array = root.optJSONArray("documents") ?: return emptyList()
            (0 until array.length()).map { i ->
                val obj = array.getJSONObject(i)
                val tagsArray = obj.optJSONArray("tags")
                val tags = if (tagsArray != null) {
                    (0 until tagsArray.length()).map { j ->
                        val t = tagsArray.getJSONObject(j)
                        PapraTag(id = t.optString("id"), name = t.optString("name"), color = t.optString("color"))
                    }
                } else emptyList()
                PapraDocument(
                    id = obj.optString("id"),
                    name = obj.optString("name", "Untitled"),
                    createdAt = obj.optString("createdAt"),
                    size = obj.optLong("fileSize", 0L),
                    mimeType = obj.optString("mimeType", ""),
                    tags = tags
                )
            }
        } catch (e: Exception) { emptyList() }
    }

    private fun parseTags(json: String): List<PapraTag> {
        return try {
            val root = JSONObject(json)
            val array = root.optJSONArray("tags") ?: return emptyList()
            (0 until array.length()).map { i ->
                val obj = array.getJSONObject(i)
                PapraTag(id = obj.optString("id"), name = obj.optString("name"), color = obj.optString("color"))
            }
        } catch (e: Exception) { emptyList() }
    }
}
