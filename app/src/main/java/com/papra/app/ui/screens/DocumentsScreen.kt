package com.papra.app.ui.screens

import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.core.content.FileProvider
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

enum class SortField { NAME, DATE }
enum class SortOrder { ASC, DESC }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DocumentsScreen(
    onOpenPdf: (filePath: String, name: String) -> Unit,
    onOpenImage: (filePath: String, name: String) -> Unit
) {
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
    var tagTarget by remember { mutableStateOf<PapraDocument?>(null) }
    var renameTarget by remember { mutableStateOf<PapraDocument?>(null) }
    var renameValue by remember { mutableStateOf("") }
    var availableTags by remember { mutableStateOf<List<PapraTag>>(emptyList()) }
    var openingDocId by remember { mutableStateOf<String?>(null) }
    var showCreateTag by remember { mutableStateOf(false) }
    var newTagName by remember { mutableStateOf("") }
    var newTagColor by remember { mutableStateOf("#3B82F6") }
    var sortField by remember { mutableStateOf(SortField.DATE) }
    var sortOrder by remember { mutableStateOf(SortOrder.DESC) }
    var showSortMenu by remember { mutableStateOf(false) }

    val sortedDocuments = remember(documents, sortField, sortOrder) {
        val sorted = when (sortField) {
            SortField.NAME -> documents.sortedBy { it.name.lowercase() }
            SortField.DATE -> documents.sortedBy { it.createdAt }
        }
        if (sortOrder == SortOrder.DESC) sorted.reversed() else sorted
    }

    suspend fun load(query: String = "") {
        isLoading = true
        errorMessage = null
        settings = settingsRepo.settings.first()
        if (settings.isConfigured) {
            when (val r = api.listDocuments(settings.baseUrl, settings.apiKey, settings.organizationId, query)) {
                is ApiResult.Success -> documents = r.data
                is ApiResult.Error -> errorMessage = "Error ${r.code}: ${r.message}"
                is ApiResult.NetworkError -> errorMessage = "Network error: ${r.message}"
            }
        }
        isLoading = false
    }

    suspend fun loadTags() {
        if (!settings.isConfigured) return
        when (val r = api.listTags(settings.baseUrl, settings.apiKey, settings.organizationId)) {
            is ApiResult.Success -> availableTags = r.data
            else -> {}
        }
    }

    LaunchedEffect(Unit) { load(); loadTags() }

    // ── Delete dialog ─────────────────────────────────────────────────────────
    deleteTarget?.let { doc ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            icon = { Icon(Icons.Default.DeleteForever, contentDescription = null) },
            title = { Text("Delete document?") },
            text = { Text("\"${doc.name}\" will be permanently deleted.") },
            confirmButton = {
                Button(
                    onClick = {
                        val target = deleteTarget; deleteTarget = null
                        scope.launch {
                            when (api.deleteDocument(settings.baseUrl, settings.apiKey, settings.organizationId, target!!.id)) {
                                is ApiResult.Success -> { documents = documents.filter { it.id != target.id }; snackbarHostState.showSnackbar("Deleted") }
                                else -> snackbarHostState.showSnackbar("Delete failed")
                            }
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                ) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Cancel") } }
        )
    }

    // ── Rename dialog ─────────────────────────────────────────────────────────
    renameTarget?.let { doc ->
        AlertDialog(
            onDismissRequest = { renameTarget = null },
            title = { Text("Rename document") },
            text = {
                OutlinedTextField(
                    value = renameValue,
                    onValueChange = { renameValue = it },
                    label = { Text("Name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        val target = renameTarget; renameTarget = null
                        scope.launch {
                            when (val r = api.renameDocument(settings.baseUrl, settings.apiKey, settings.organizationId, target!!.id, renameValue)) {
                                is ApiResult.Success -> {
                                    documents = documents.map { if (it.id == target.id) it.copy(name = renameValue) else it }
                                    snackbarHostState.showSnackbar("Renamed")
                                }
                                else -> snackbarHostState.showSnackbar("Rename failed")
                            }
                        }
                    },
                    enabled = renameValue.isNotBlank()
                ) { Text("Rename") }
            },
            dismissButton = { TextButton(onClick = { renameTarget = null }) { Text("Cancel") } }
        )
    }

    // ── Tag manager dialog ────────────────────────────────────────────────────
    tagTarget?.let { doc ->
        TagManagerDialog(
            document = doc,
            availableTags = availableTags,
            onDismiss = { tagTarget = null },
            onAddTag = { tagId ->
                scope.launch {
                    api.addTagToDocument(settings.baseUrl, settings.apiKey, settings.organizationId, doc.id, tagId)
                    load(searchQuery)
                }
            },
            onRemoveTag = { tagId ->
                scope.launch {
                    api.removeTagFromDocument(settings.baseUrl, settings.apiKey, settings.organizationId, doc.id, tagId)
                    load(searchQuery)
                }
            },
            onCreateTag = { showCreateTag = true }
        )
    }

    // ── Create tag dialog ─────────────────────────────────────────────────────
    if (showCreateTag) {
        AlertDialog(
            onDismissRequest = { showCreateTag = false },
            title = { Text("Create tag") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(value = newTagName, onValueChange = { newTagName = it },
                        label = { Text("Tag name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(
                        value = newTagColor, onValueChange = { newTagColor = it },
                        label = { Text("Color (hex)") }, placeholder = { Text("#3B82F6") },
                        singleLine = true, modifier = Modifier.fillMaxWidth(),
                        leadingIcon = {
                            val c = remember(newTagColor) {
                                try { Color(android.graphics.Color.parseColor(newTagColor)) } catch (e: Exception) { Color.Gray }
                            }
                            Box(Modifier.size(20.dp).background(c, CircleShape))
                        }
                    )
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        showCreateTag = false
                        scope.launch {
                            val r = api.createTag(settings.baseUrl, settings.apiKey, settings.organizationId, newTagName, newTagColor)
                            if (r is ApiResult.Success) { availableTags = availableTags + r.data; snackbarHostState.showSnackbar("Tag created"); newTagName = "" }
                            else snackbarHostState.showSnackbar("Failed to create tag")
                        }
                    },
                    enabled = newTagName.isNotBlank()
                ) { Text("Create") }
            },
            dismissButton = { TextButton(onClick = { showCreateTag = false }) { Text("Cancel") } }
        )
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            if (isSearching) {
                SearchTopBar(
                    query = searchQuery,
                    onQueryChange = { searchQuery = it },
                    onSearch = { scope.launch { load(it) } },
                    onClose = { isSearching = false; searchQuery = ""; scope.launch { load() } }
                )
            } else {
                TopAppBar(
                    title = { Text("Documents", fontWeight = FontWeight.SemiBold) },
                    actions = {
                        IconButton(onClick = { isSearching = true }) { Icon(Icons.Default.Search, "Search") }
                        IconButton(onClick = { showCreateTag = true }) { Icon(Icons.Default.NewLabel, "Create tag") }
                        Box {
                            IconButton(onClick = { showSortMenu = true }) { Icon(Icons.Default.Sort, "Sort") }
                            DropdownMenu(expanded = showSortMenu, onDismissRequest = { showSortMenu = false }) {
                                Text("Sort by", style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.outline,
                                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
                                DropdownMenuItem(
                                    text = { Text("Name") },
                                    onClick = { sortField = SortField.NAME; showSortMenu = false },
                                    leadingIcon = { if (sortField == SortField.NAME) Icon(Icons.Default.Check, null) }
                                )
                                DropdownMenuItem(
                                    text = { Text("Date") },
                                    onClick = { sortField = SortField.DATE; showSortMenu = false },
                                    leadingIcon = { if (sortField == SortField.DATE) Icon(Icons.Default.Check, null) }
                                )
                                HorizontalDivider()
                                DropdownMenuItem(
                                    text = { Text("Ascending") },
                                    onClick = { sortOrder = SortOrder.ASC; showSortMenu = false },
                                    leadingIcon = { if (sortOrder == SortOrder.ASC) Icon(Icons.Default.Check, null) }
                                )
                                DropdownMenuItem(
                                    text = { Text("Descending") },
                                    onClick = { sortOrder = SortOrder.DESC; showSortMenu = false },
                                    leadingIcon = { if (sortOrder == SortOrder.DESC) Icon(Icons.Default.Check, null) }
                                )
                            }
                        }
                        IconButton(onClick = { scope.launch { load(searchQuery) } }) { Icon(Icons.Default.Refresh, "Refresh") }
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
                sortedDocuments.isEmpty() && !isLoading -> CenteredMessage(
                    if (searchQuery.isBlank()) "No documents yet. Upload something!" else "No results for \"$searchQuery\""
                )
                else -> LazyColumn(
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    item {
                        Text("${sortedDocuments.size} document(s)",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.outline,
                            modifier = Modifier.padding(bottom = 4.dp))
                    }
                    items(sortedDocuments, key = { it.id }) { doc ->
                        DocumentCard(
                            doc = doc,
                            isOpening = openingDocId == doc.id,
                            onOpen = {
                                scope.launch {
                                    openingDocId = doc.id
                                    val result = api.downloadDocumentToCache(
                                        settings.baseUrl, settings.apiKey,
                                        settings.organizationId, doc.id, doc.name
                                    )
                                    openingDocId = null
                                    when (result) {
                                        is ApiResult.Success -> {
                                            val file = result.data
					val ext = doc.name.substringAfterLast('.', "").lowercase()
					val mime = doc.mimeType.ifBlank {
    						MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
						}                                            
                                            when {
                                                mime == "application/pdf" ->
                                                    onOpenPdf(file.absolutePath, doc.name)
                                                mime.startsWith("image/") ->
                                                    onOpenImage(file.absolutePath, doc.name)
                                                else -> {
                                                    // External app for everything else
                                                    val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
                                                    val intent = Intent(Intent.ACTION_VIEW).apply {
                                                        setDataAndType(uri, mime)
                                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                                    }
                                                    context.startActivity(Intent.createChooser(intent, "Open with"))
                                                }
                                            }
                                        }
                                        else -> snackbarHostState.showSnackbar("Failed to open document")
                                    }
                                }
                            },
                            onTag = { tagTarget = doc },
                            onRename = { renameTarget = doc; renameValue = doc.name },
                            onDelete = { deleteTarget = doc }
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun TagManagerDialog(
    document: PapraDocument,
    availableTags: List<PapraTag>,
    onDismiss: () -> Unit,
    onAddTag: (String) -> Unit,
    onRemoveTag: (String) -> Unit,
    onCreateTag: () -> Unit
) {
    val currentTagIds = document.tags.map { it.id }.toSet()
    Dialog(onDismissRequest = onDismiss) {
        Surface(shape = RoundedCornerShape(16.dp), tonalElevation = 6.dp) {
            Column(modifier = Modifier.padding(20.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Manage tags", style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    IconButton(onClick = onCreateTag) { Icon(Icons.Default.Add, "Create tag") }
                }
                Text(document.name, style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.outline, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(16.dp))
                if (availableTags.isEmpty()) {
                    Text("No tags yet. Create one first.", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.outline)
                } else {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        availableTags.forEach { tag ->
                            val applied = tag.id in currentTagIds
                            FilterChip(
                                selected = applied,
                                onClick = { if (applied) onRemoveTag(tag.id) else onAddTag(tag.id) },
                                label = { Text(tag.name) },
                                leadingIcon = if (applied) { { Icon(Icons.Default.Check, null, Modifier.size(16.dp)) } } else null
                            )
                        }
                    }
                }
                Spacer(Modifier.height(16.dp))
                TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.End)) { Text("Done") }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SearchTopBar(query: String, onQueryChange: (String) -> Unit, onSearch: (String) -> Unit, onClose: () -> Unit) {
    val keyboard = LocalSoftwareKeyboardController.current
    TopAppBar(
        navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.Default.ArrowBack, "Close search") } },
        title = {
            OutlinedTextField(
                value = query, onValueChange = onQueryChange,
                placeholder = { Text("Search documents...") }, singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { onSearch(query); keyboard?.hide() }),
                trailingIcon = { if (query.isNotBlank()) IconButton(onClick = { onQueryChange("") }) { Icon(Icons.Default.Clear, "Clear") } }
            )
        },
        actions = { IconButton(onClick = { onSearch(query); keyboard?.hide() }) { Icon(Icons.Default.Search, "Search") } }
    )
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DocumentCard(
    doc: PapraDocument,
    isOpening: Boolean,
    onOpen: () -> Unit,
    onTag: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit
) {
    var showMenu by remember { mutableStateOf(false) }

    Surface(
        shape = RoundedCornerShape(10.dp),
        tonalElevation = 1.dp,
        modifier = Modifier.fillMaxWidth().clickable(enabled = !isOpening, onClick = onOpen)
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier.size(40.dp).clip(RoundedCornerShape(8.dp))
                        .background(fileTypeColor(doc.mimeType).copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center
                ) {
                    if (isOpening) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    else Icon(fileTypeIcon(doc.mimeType), null, tint = fileTypeColor(doc.mimeType), modifier = Modifier.size(22.dp))
                }
                Spacer(Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(doc.name, style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (doc.createdAt.isNotBlank())
                            Text(formatDate(doc.createdAt), style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.outline)
                        if (doc.size > 0)
                            Text(formatSize(doc.size), style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.outline)
                    }
                }
                Box {
                    IconButton(onClick = { showMenu = true }, modifier = Modifier.size(32.dp)) {
                        Icon(Icons.Default.MoreVert, "More", modifier = Modifier.size(18.dp))
                    }
                    DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
                        DropdownMenuItem(text = { Text("Manage tags") }, onClick = { showMenu = false; onTag() },
                            leadingIcon = { Icon(Icons.Default.Label, null) })
                        DropdownMenuItem(text = { Text("Rename") }, onClick = { showMenu = false; onRename() },
                            leadingIcon = { Icon(Icons.Default.Edit, null) })
                        DropdownMenuItem(text = { Text("Delete", color = MaterialTheme.colorScheme.error) },
                            onClick = { showMenu = false; onDelete() },
                            leadingIcon = { Icon(Icons.Default.Delete, null, tint = MaterialTheme.colorScheme.error) })
                    }
                }
            }
            if (doc.tags.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    doc.tags.forEach { tag -> TagChip(tag) }
                }
            }
        }
    }
}

@Composable
private fun TagChip(tag: PapraTag) {
    val parsedColor = remember(tag.color) {
        if (tag.color.isNotBlank()) try { android.graphics.Color.parseColor(tag.color) } catch (e: Exception) { null } else null
    }
    val color = if (parsedColor != null) Color(parsedColor) else MaterialTheme.colorScheme.secondaryContainer
    Surface(color = color.copy(alpha = 0.2f), shape = RoundedCornerShape(4.dp)) {
        Text(tag.name, modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurface)
    }
}

@Composable
private fun CenteredMessage(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text, color = MaterialTheme.colorScheme.outline, style = MaterialTheme.typography.bodyMedium)
    }
}

private fun fileTypeIcon(mime: String): ImageVector = when {
    mime.startsWith("image/") -> Icons.Default.Image
    mime == "application/pdf" -> Icons.Default.PictureAsPdf
    mime.startsWith("video/") -> Icons.Default.VideoFile
    mime.startsWith("audio/") -> Icons.Default.AudioFile
    mime.contains("spreadsheet") || mime.contains("excel") -> Icons.Default.TableChart
    mime.contains("presentation") || mime.contains("powerpoint") -> Icons.Default.Slideshow
    mime.contains("word") || mime.contains("document") -> Icons.Default.Article
    mime.startsWith("text/") -> Icons.Default.TextSnippet
    else -> Icons.Default.Description
}

private fun fileTypeColor(mime: String): Color = when {
    mime.startsWith("image/") -> Color(0xFF10B981)
    mime == "application/pdf" -> Color(0xFFEF4444)
    mime.startsWith("video/") -> Color(0xFF8B5CF6)
    mime.startsWith("audio/") -> Color(0xFFF59E0B)
    mime.contains("spreadsheet") || mime.contains("excel") -> Color(0xFF22C55E)
    mime.contains("presentation") || mime.contains("powerpoint") -> Color(0xFFF97316)
    mime.contains("word") || mime.contains("document") -> Color(0xFF3B82F6)
    else -> Color(0xFF6B7280)
}

private fun formatDate(iso: String): String = try {
    DateTimeFormatter.ofPattern("d MMM yyyy").withZone(ZoneId.systemDefault()).format(Instant.parse(iso))
} catch (e: Exception) { iso }

private fun formatSize(bytes: Long): String {
    val kb = bytes / 1024.0; val mb = kb / 1024.0
    return when { mb >= 1 -> "%.1f MB".format(mb); kb >= 1 -> "%.0f KB".format(kb); else -> "$bytes B" }
}
