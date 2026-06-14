package com.papra.app.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.papra.app.data.api.ApiResult
import com.papra.app.data.api.PapraApiClient
import com.papra.app.data.api.PapraDocument
import com.papra.app.data.datastore.PapraSettings
import com.papra.app.data.datastore.SettingsRepository
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DocumentsScreen() {
    val context = LocalContext.current
    val api = remember { PapraApiClient(context) }
    val settingsRepo = remember { SettingsRepository(context) }
    val scope = rememberCoroutineScope()

    var documents by remember { mutableStateOf<List<PapraDocument>>(emptyList()) }
    var isLoading by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var settings by remember { mutableStateOf(PapraSettings()) }

    LaunchedEffect(Unit) {
        settings = settingsRepo.settings.first()
        if (settings.isConfigured) {
            loadDocuments(api, settings) { docs, error ->
                documents = docs
                errorMessage = error
            }
        }
    }

    fun refresh() {
        scope.launch {
            isLoading = true
            errorMessage = null
            settings = settingsRepo.settings.first()
            if (settings.isConfigured) {
                loadDocuments(api, settings) { docs, error ->
                    documents = docs
                    errorMessage = error
                }
            }
            isLoading = false
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Documents", fontWeight = FontWeight.SemiBold) },
                actions = {
                    IconButton(onClick = { refresh() }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                    }
                }
            )
        }
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = isLoading,
            onRefresh = { refresh() },
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            when {
                !settings.isConfigured -> {
                    CenteredMessage("Configure your Papra instance in Settings")
                }
                errorMessage != null -> {
                    CenteredMessage(errorMessage ?: "Unknown error")
                }
                documents.isEmpty() && !isLoading -> {
                    CenteredMessage("No documents yet. Upload something!")
                }
                else -> {
                    LazyColumn(
                        contentPadding = PaddingValues(16.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        items(documents, key = { it.id }) { doc ->
                            DocumentCard(doc)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DocumentCard(doc: PapraDocument) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        tonalElevation = 1.dp,
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier.padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                Icons.Default.Description,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(24.dp)
            )
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    doc.name,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                if (doc.createdAt.isNotBlank()) {
                    Text(
                        formatDate(doc.createdAt),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.outline
                    )
                }
            }
        }
    }
}

@Composable
private fun CenteredMessage(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text, color = MaterialTheme.colorScheme.outline, style = MaterialTheme.typography.bodyMedium)
    }
}

private suspend fun loadDocuments(
    api: PapraApiClient,
    settings: PapraSettings,
    callback: (List<PapraDocument>, String?) -> Unit
) {
    when (val result = api.listDocuments(settings.baseUrl, settings.apiKey, settings.organizationId)) {
        is ApiResult.Success -> callback(result.data, null)
        is ApiResult.Error -> callback(emptyList(), "Error ${result.code}: ${result.message}")
        is ApiResult.NetworkError -> callback(emptyList(), "Network error: ${result.message}")
    }
}

private fun formatDate(iso: String): String {
    return try {
        val instant = Instant.parse(iso)
        val formatter = DateTimeFormatter.ofPattern("d MMM yyyy")
            .withZone(ZoneId.systemDefault())
        formatter.format(instant)
    } catch (e: Exception) {
        iso
    }
}
