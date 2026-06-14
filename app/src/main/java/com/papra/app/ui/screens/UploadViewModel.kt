package com.papra.app.ui.screens

import android.app.Application
import android.net.Uri
import android.provider.OpenableColumns
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.papra.app.data.api.ApiResult
import com.papra.app.data.api.PapraApiClient
import com.papra.app.data.datastore.PapraSettings
import com.papra.app.data.datastore.SettingsRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class UploadStatus { PENDING, UPLOADING, DONE, FAILED }

data class FileUploadItem(
    val uri: Uri,
    val name: String,
    val size: Long,
    val status: UploadStatus = UploadStatus.PENDING,
    val progress: Int = 0,
    val errorMessage: String? = null
)

data class UploadScreenState(
    val files: List<FileUploadItem> = emptyList(),
    val isUploading: Boolean = false,
    val snackbarMessage: String? = null,
    val settings: PapraSettings = PapraSettings()
)

class UploadViewModel(application: Application) : AndroidViewModel(application) {
    private val context = application.applicationContext
    private val api = PapraApiClient(context)
    private val settingsRepo = SettingsRepository(context)

    companion object {
        val Factory: ViewModelProvider.Factory = ViewModelProvider.AndroidViewModelFactory()
    }

    private val _state = MutableStateFlow(UploadScreenState())
    val state: StateFlow<UploadScreenState> = _state

    init {
        viewModelScope.launch {
            settingsRepo.settings.collect { settings ->
                _state.update { it.copy(settings = settings) }
            }
        }
    }

    fun addFiles(uris: List<Uri>) {
        val newItems = uris.map { uri ->
            FileUploadItem(
                uri = uri,
                name = resolveFileName(uri),
                size = resolveFileSize(uri)
            )
        }
        _state.update { it.copy(files = it.files + newItems) }
    }

    fun removeFile(uri: Uri) {
        _state.update { it.copy(files = it.files.filter { f -> f.uri != uri }) }
    }

    fun clearAll() {
        _state.update { it.copy(files = emptyList()) }
    }

    fun uploadAll() {
        val settings = _state.value.settings
        if (!settings.isConfigured) {
            _state.update { it.copy(snackbarMessage = "Please configure settings first") }
            return
        }

        val pendingFiles = _state.value.files.filter {
            it.status == UploadStatus.PENDING || it.status == UploadStatus.FAILED
        }
        if (pendingFiles.isEmpty()) return

        viewModelScope.launch {
            _state.update { it.copy(isUploading = true) }

            pendingFiles.forEach { item ->
                setFileStatus(item.uri, UploadStatus.UPLOADING)

                val result = api.uploadDocument(
                    baseUrl = settings.baseUrl,
                    apiKey = settings.apiKey,
                    organizationId = settings.organizationId,
                    uri = item.uri,
                    onProgress = { progress ->
                        updateFileProgress(item.uri, progress)
                    }
                )

                when (result) {
                    is ApiResult.Success -> setFileStatus(item.uri, UploadStatus.DONE)
                    is ApiResult.Error -> setFileError(item.uri, result.message)
                    is ApiResult.NetworkError -> setFileError(item.uri, result.message)
                }
            }

            val doneCount = _state.value.files.count { it.status == UploadStatus.DONE }
            val failCount = _state.value.files.count { it.status == UploadStatus.FAILED }

            _state.update {
                it.copy(
                    isUploading = false,
                    snackbarMessage = when {
                        failCount == 0 -> "$doneCount file(s) uploaded successfully"
                        doneCount == 0 -> "All uploads failed"
                        else -> "$doneCount uploaded, $failCount failed"
                    }
                )
            }
        }
    }

    fun retryFile(uri: Uri) {
        _state.update {
            it.copy(
                files = it.files.map { f ->
                    if (f.uri == uri) f.copy(status = UploadStatus.PENDING, progress = 0, errorMessage = null)
                    else f
                }
            )
        }
        uploadAll()
    }

    fun clearSnackbar() {
        _state.update { it.copy(snackbarMessage = null) }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private fun setFileStatus(uri: Uri, status: UploadStatus) {
        _state.update {
            it.copy(files = it.files.map { f -> if (f.uri == uri) f.copy(status = status) else f })
        }
    }

    private fun updateFileProgress(uri: Uri, progress: Int) {
        _state.update {
            it.copy(files = it.files.map { f -> if (f.uri == uri) f.copy(progress = progress) else f })
        }
    }

    private fun setFileError(uri: Uri, message: String) {
        _state.update {
            it.copy(
                files = it.files.map { f ->
                    if (f.uri == uri) f.copy(status = UploadStatus.FAILED, errorMessage = message) else f
                }
            )
        }
    }

    private fun resolveFileName(uri: Uri): String {
        var name = uri.lastPathSegment ?: "document"
        context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val col = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (cursor.moveToFirst() && col >= 0) name = cursor.getString(col)
        }
        return name
    }

    private fun resolveFileSize(uri: Uri): Long {
        context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val col = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (cursor.moveToFirst() && col >= 0) return cursor.getLong(col)
        }
        return 0L
    }
}
