package com.papra.app.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.papra.app.data.api.ApiResult
import com.papra.app.data.api.PapraApiClient
import com.papra.app.data.api.PapraDocument
import com.papra.app.data.api.PapraTag
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
    val snackbarHostState = remember { SnackbarHostState() }

    var documents by remember { mutableStateOf<List<PapraDocument>>(emptyList()) }
    var isLoading by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var settings by remember { mutableStateOf(PapraSettings()) }
    var searchQuery by remember { mutableStateOf("") }
    var isSearching by remember { mutableStateOf(false) }
    var deleteTarget by remember { mutableStateOf<PapraDocument?>(null) }

    suspend fun load(query: String = "") {
        isLoading = true
        errorMessage = null
        settings = settingsRepo.settings.first()
        if (settings.isConfigured) {
            when (val result = api.listDocuments(settings.baseUrl, settings.apiKey, settings.organizationId, query)) {
                is ApiResult.Success -> documents = result.data
                is ApiResult.Error -> errorMessage = "Error ${result.code}: ${result.message}"
                is ApiResult.NetworkError -> errorMessage = "Network error: ${result.message}"
            }
        }
        isLoading = false
    }

    LaunchedEffect(Unit) { load() }

    // Delete confirmation dialog
    deleteTarget?.let { doc ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            icon = { Icon(Icons.Default.DeleteForever, contentDescription = null) },
            title = { Text("Delete document?") },
            text = {
                Text("\"${doc.name}\" will be permanently deleted from Papra.",
                    style = MaterialTheme.typography.bodyMedium)
            },
            confirmButton = {
                Button(
                    onClick = {
                        deleteTarget = null
                        scope.launch {
                            val result = api.deleteDocument(
                                settings.baseUrl, settings.apiKey,
                                settings.organizationId, doc.id
                            )
                            when (result) {
                                is ApiResult.Success -> {
                                    documents = documents.filter { it.id != doc.id }
                                    snackbarHostState.showSnackbar("Deleted successfully")
                                }
                                is ApiResult.Error -> snackbarHostState.showSnackbar("Delete failed: ${result.message}")
                                is ApiResult.NetworkError -> snackbarHostState.showSnackbar("Network error")
                            }
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                ) { Text("Delete") }
            },
            dismissButton = {
                TextButton(onClick = { deleteTarget = null }) { Text("Cancel") }
            }
        )
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            if (isSearching) {
                SearchBar(
                    query = searchQuery,
                    onQueryChange = { searchQuery = it },
                    onSearch = { scope.launch { load(it) } },
                    onClose = {
                        isSearching = false
                        searchQuery = ""
                        scope.launch { load() }
                    }
                )
            } else {
                TopAppBar(
                    title = { Text("Documents", fontWeight = FontWeight.SemiBold) },
                    actions = {
                        IconButton(onClick = { isSearching = true }) {
                            Icon(Icons.Default.Search, contentDescription = "Search")
                        }
                        IconButton(onClick = { scope.launch { load(searchQuery) } }) {
                            Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                        }
                    }
                )
            }
        }
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = isLoading,
            onRefresh = { scope.launch { load(searchQuery) } },
            modifier = Modifier.fillMaxSize().padding(padding)
        ) {
            when {
                !settings.isConfigured -> CenteredMessage("Configure your Papra instance in Settings")
                errorMessage != null -> CenteredMessage(errorMessage ?: "Unknown error")
                documents.isEmpty() && !isLoading -> CenteredMessage(
                    if (searchQuery.isBlank()) "No documents yet. Upload something!"
                    else "No results for \"$searchQuery\""
                )
                else -> {
                    LazyColumn(
                        contentPadding = PaddingValues(16.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        item {
                            Text("${documents.size} document(s)",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.outline,
                                modifier = Modifier.padding(bottom = 4.dp))
                        }
                        items(documents, key = { it.id }) { doc ->
                            DocumentCard(doc, onDelete = { deleteTarget = doc })
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SearchBar(
    query: String,
    onQueryChange: (String) -> Unit,
    onSearch: (String) -> Unit,
    onClose: () -> Unit
) {
    val scope = rememberCoroutineScope()
    TopAppBar(
        title = {
            OutlinedTextField(
                value = query,
                onValueChange = onQueryChange,
                placeholder = { Text("Search documents...") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                trailingIcon = {
                    if (query.isNotBlank()) {
                        IconButton(onClick = { onQueryChange("") }) {
                            Icon(Icons.Default.Clear, contentDescription = "Clear")
                        }
                    }
                }
            )
        },
        navigationIcon = {
            IconButton(onClick = onClose) {
                Icon(Icons.Default.ArrowBack, contentDescription = "Close search")
            }
        },
        actions = {
            IconButton(onClick = { onSearch(query) }) {
                Icon(Icons.Default.Search, contentDescription = "Search")
            }
        }
    )
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DocumentCard(doc: PapraDocument, onDelete: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        tonalElevation = 1.dp,
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Description, contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(24.dp))
                Spacer(Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(doc.name, style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (doc.createdAt.isNotBlank()) {
                        Text(formatDate(doc.createdAt), style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.outline)
                    }
                }
                IconButton(onClick = onDelete, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Default.Delete, contentDescription = "Delete",
                        modifier = Modifier.size(18.dp),
                        tint = MaterialTheme.colorScheme.error)
                }
            }

            // Tags
            if (doc.tags.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    doc.tags.forEach { tag ->
                        TagChip(tag)
                    }
                }
            }
        }
    }
}

@Composable
private fun TagChip(tag: PapraTag) {
    val color = try {
        if (tag.color.isNotBlank()) Color(android.graphics.Color.parseColor(tag.color))
        else MaterialTheme.colorScheme.secondaryContainer
    } catch (e: Exception) {
        MaterialTheme.colorScheme.secondaryContainer
    }

    Surface(
        color = color.copy(alpha = 0.2f),
        shape = RoundedCornerShape(4.dp)
    ) {
        Text(
            tag.name,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}

@Composable
private fun CenteredMessage(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text, color = MaterialTheme.colorScheme.outline,
            style = MaterialTheme.typography.bodyMedium)
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
