package com.papra.app.ui.screens

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.papra.app.data.api.ApiResult
import com.papra.app.data.api.PapraApiClient
import com.papra.app.data.api.PapraDocument
import com.papra.app.data.api.PapraTag
import com.papra.app.data.datastore.PapraSettings
import com.papra.app.data.datastore.SettingsRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
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
    var renameTarget by remember { mutableStateOf<PapraDocument?>(null) }
    var viewTarget by remember { mutableStateOf<PapraDocument?>(null) }
    var tagManagerTarget by remember { mutableStateOf<PapraDocument?>(null) }
    var createTagOpen by remember { mutableStateOf(false) }

    var sortBy by remember { mutableStateOf("createdAt") }
    var sortOrder by remember { mutableStateOf("desc") }
    var sortMenuOpen by remember { mutableStateOf(false) }

    suspend fun load(query: String = "") {
        isLoading = true
        errorMessage = null
        settings = settingsRepo.settings.first()
        if (settings.isConfigured) {
            when (val result = api.listDocuments(
                settings.baseUrl, settings.apiKey, settings.organizationId,
                query, sortBy, sortOrder
            )) {
                is ApiResult.Success -> documents = result.data
                is ApiResult.Error -> errorMessage = "Error ${result.code}: ${result.message}"
                is ApiResult.NetworkError -> errorMessage = "Network error: ${result.message}"
            }
        }
        isLoading = false
    }

    LaunchedEffect(Unit) { load() }

    // View document dialog / screen
    viewTarget?.let { doc ->
        DocumentViewerDialog(
            document = doc,
            settings = settings,
            api = api,
            onDismiss = { viewTarget = null }
        )
    }

    // Tag manager dialog
    tagManagerTarget?.let { doc ->
        TagManagerDialog(
            document = doc,
            settings = settings,
            api = api,
            onDismiss = { tagManagerTarget = null },
            onUpdated = { scope.launch { load(searchQuery) } }
        )
    }

    // Create tag dialog
    if (createTagOpen) {
        CreateTagDialog(
            settings = settings,
            api = api,
            onDismiss = { createTagOpen = false },
            onCreated = { scope.launch { load(searchQuery) } }
        )
    }

    // Rename dialog
    renameTarget?.let { doc ->
        var newName by remember { mutableStateOf(doc.name) }
        AlertDialog(
            onDismissRequest = { renameTarget = null },
            title = { Text("Rename document") },
            text = {
                OutlinedTextField(
                    value = newName,
                    onValueChange = { newName = it },
                    label = { Text("New name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        renameTarget = null
                        scope.launch {
                            val result = api.renameDocument(
                                settings.baseUrl, settings.apiKey,
                                settings.organizationId, doc.id, newName
                            )
                            when (result) {
                                is ApiResult.Success -> {
                                    documents = documents.map {
                                        if (it.id == doc.id) it.copy(name = newName) else it
                                    }
                                    snackbarHostState.showSnackbar("Renamed successfully")
                                }
                                else -> snackbarHostState.showSnackbar("Rename failed")
                            }
                        }
                    }
                ) { Text("Save") }
            },
            dismissButton = {
                TextButton(onClick = { renameTarget = null }) { Text("Cancel") }
            }
        )
    }

    // Delete confirmation
    deleteTarget?.let { doc ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            icon = { Icon(Icons.Default.DeleteForever, contentDescription = null) },
            title = { Text("Delete document?") },
            text = {
                Text("\"${doc.name}\" will be permanently deleted.",
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
                                    snackbarHostState.showSnackbar("Deleted")
                                }
                                else -> snackbarHostState.showSnackbar("Delete failed")
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
                        IconButton(onClick = { createTagOpen = true }) {
                            Icon(Icons.Default.NewLabel, contentDescription = "Create tag")
                        }
                        Box {
                            IconButton(onClick = { sortMenuOpen = true }) {
                                Icon(Icons.Default.Sort, contentDescription = "Sort")
                            }
                            DropdownMenu(
                                expanded = sortMenuOpen,
                                onDismissRequest = { sortMenuOpen = false }
                            ) {
                                DropdownMenuItem(
                                    text = { Text("Date (newest first)") },
                                    onClick = {
                                        sortBy = "createdAt"; sortOrder = "desc"
                                        sortMenuOpen = false; scope.launch { load(searchQuery) }
                                    },
                                    leadingIcon = if (sortBy == "createdAt" && sortOrder == "desc") {
                                        { Icon(Icons.Default.Check, null, modifier = Modifier.size(16.dp)) }
                                    } else null
                                )
                                DropdownMenuItem(
                                    text = { Text("Date (oldest first)") },
                                    onClick = {
                                        sortBy = "createdAt"; sortOrder = "asc"
                                        sortMenuOpen = false; scope.launch { load(searchQuery) }
                                    },
                                    leadingIcon = if (sortBy == "createdAt" && sortOrder == "asc") {
                                        { Icon(Icons.Default.Check, null, modifier = Modifier.size(16.dp)) }
                                    } else null
                                )
                                DropdownMenuItem(
                                    text = { Text("Name (A-Z)") },
                                    onClick = {
                                        sortBy = "name"; sortOrder = "asc"
                                        sortMenuOpen = false; scope.launch { load(searchQuery) }
                                    },
                                    leadingIcon = if (sortBy == "name" && sortOrder == "asc") {
                                        { Icon(Icons.Default.Check, null, modifier = Modifier.size(16.dp)) }
                                    } else null
                                )
                                DropdownMenuItem(
                                    text = { Text("Name (Z-A)") },
                                    onClick = {
                                        sortBy = "name"; sortOrder = "desc"
                                        sortMenuOpen = false; scope.launch { load(searchQuery) }
                                    },
                                    leadingIcon = if (sortBy == "name" && sortOrder == "desc") {
                                        { Icon(Icons.Default.Check, null, modifier = Modifier.size(16.dp)) }
                                    } else null
                                )
                            }
                        }
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
                            DocumentCard(
                                doc = doc,
                                settings = settings,
                                api = api,
                                onDelete = { deleteTarget = doc },
                                onRename = { renameTarget = doc },
                                onView = { viewTarget = doc },
                                onManageTags = { tagManagerTarget = doc }
                            )
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

@Composable
private fun DocumentCard(
    doc: PapraDocument,
    settings: PapraSettings,
    api: PapraApiClient,
    onDelete: () -> Unit,
    onRename: () -> Unit,
    onView: () -> Unit,
    onManageTags: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var thumbnail by remember { mutableStateOf<Bitmap?>(null) }
    var isImage by remember { mutableStateOf(false) }

    LaunchedEffect(doc.id) {
        if (doc.mimeType.startsWith("image/")) {
            isImage = true
            val result = api.downloadToCache(
                settings.baseUrl, settings.apiKey,
                settings.organizationId, doc.id, doc.name
            )
            if (result is ApiResult.Success) {
                thumbnail = withContext(Dispatchers.IO) {
                    try {
                        android.graphics.BitmapFactory.decodeFile(result.data.absolutePath)
                    } catch (e: Exception) { null }
                }
            }
        }
    }

    Surface(
        shape = RoundedCornerShape(10.dp),
        tonalElevation = 1.dp,
        modifier = Modifier.fillMaxWidth().clickable { onView() }
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                // Thumbnail or icon
                if (isImage && thumbnail != null) {
                    Image(
                        bitmap = thumbnail!!.asImageBitmap(),
                        contentDescription = null,
                        modifier = Modifier
                            .size(48.dp)
                            .clip(RoundedCornerShape(6.dp)),
                        contentScale = ContentScale.Crop
                    )
                } else {
                    val iconTint = when {
                        doc.mimeType.contains("pdf") -> Color(0xFFE53935)
                        doc.mimeType.startsWith("image/") -> Color(0xFF43A047)
                        doc.mimeType.contains("video") -> Color(0xFF7E57C2)
                        doc.mimeType.contains("audio") -> Color(0xFFFB8C00)
                        else -> MaterialTheme.colorScheme.primary
                    }
                    Icon(
                        imageVector = when {
                            doc.mimeType.contains("pdf") -> Icons.Default.PictureAsPdf
                            doc.mimeType.startsWith("image/") -> Icons.Default.Image
                            doc.mimeType.contains("video") -> Icons.Default.VideoFile
                            doc.mimeType.contains("audio") -> Icons.Default.AudioFile
                            else -> Icons.Default.Description
                        },
                        contentDescription = null,
                        tint = iconTint,
                        modifier = Modifier.size(48.dp)
                    )
                }

                Spacer(Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(doc.name,
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(formatDate(doc.createdAt),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.outline)
                        Spacer(Modifier.width(8.dp))
                        Text(formatSize(doc.size),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.outlineVariant)
                    }
                }

                // Actions
                var menuOpen by remember { mutableStateOf(false) }
                Box {
                    IconButton(onClick = { menuOpen = true }, modifier = Modifier.size(32.dp)) {
                        Icon(Icons.Default.MoreVert, contentDescription = "More", modifier = Modifier.size(18.dp))
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(
                            text = { Text("View") },
                            onClick = { menuOpen = false; onView() },
                            leadingIcon = { Icon(Icons.Default.Visibility, null) }
                        )
                        DropdownMenuItem(
                            text = { Text("Rename") },
                            onClick = { menuOpen = false; onRename() },
                            leadingIcon = { Icon(Icons.Default.Edit, null) }
                        )
                        DropdownMenuItem(
                            text = { Text("Tags") },
                            onClick = { menuOpen = false; onManageTags() },
                            leadingIcon = { Icon(Icons.Default.Label, null) }
                        )
                        DropdownMenuItem(
                            text = { Text("Delete") },
                            onClick = { menuOpen = false; onDelete() },
                            leadingIcon = { Icon(Icons.Default.Delete, null, tint = MaterialTheme.colorScheme.error) }
                        )
                    }
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
    val parsedColor = remember(tag.color) {
        if (tag.color.isNotBlank()) {
            try { android.graphics.Color.parseColor(tag.color) } catch (e: Exception) { null }
        } else null
    }
    val color = if (parsedColor != null) Color(parsedColor) else MaterialTheme.colorScheme.secondaryContainer

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

private fun formatSize(bytes: Long): String {
    if (bytes <= 0) return "unknown"
    val kb = bytes / 1024.0
    val mb = kb / 1024.0
    return when {
        mb >= 1 -> "%.1f MB".format(mb)
        kb >= 1 -> "%.0f KB".format(kb)
        else -> "$bytes B"
    }
}

// ── Document Viewer Dialog ────────────────────────────────────────────────

@Composable
private fun DocumentViewerDialog(
    document: PapraDocument,
    settings: PapraSettings,
    api: PapraApiClient,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var isLoading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var pdfBitmaps by remember { mutableStateOf<List<Bitmap>>(emptyList()) }
    var cachedFile by remember { mutableStateOf<File?>(null) }

    LaunchedEffect(document.id) {
        val result = api.downloadToCache(
            settings.baseUrl, settings.apiKey,
            settings.organizationId, document.id, document.name
        )
        when (result) {
            is ApiResult.Success -> {
                cachedFile = result.data
                if (document.mimeType.contains("pdf")) {
                    pdfBitmaps = withContext(Dispatchers.IO) {
                        renderPdfToBitmaps(result.data)
                    }
                    isLoading = false
                } else if (document.mimeType.startsWith("image/")) {
                    isLoading = false
                } else {
                    // Open externally for other types
                    openExternal(context, result.data, document.mimeType)
                    onDismiss()
                }
            }
            is ApiResult.Error -> { error = result.message; isLoading = false }
            is ApiResult.NetworkError -> { error = result.message; isLoading = false }
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        modifier = Modifier.fillMaxWidth(),
        title = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(document.name, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                IconButton(onClick = onDismiss, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Default.Close, null)
                }
            }
        },
        text = {
            Box(modifier = Modifier.fillMaxWidth().heightIn(min = 200.dp, max = 500.dp)) {
                when {
                    isLoading -> CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
                    error != null -> Text(error!!, modifier = Modifier.align(Alignment.Center))
                    document.mimeType.contains("pdf") -> {
                        LazyColumn {
                            items(pdfBitmaps) { bitmap ->
                                Image(
                                    bitmap = bitmap.asImageBitmap(),
                                    contentDescription = null,
                                    modifier = Modifier.fillMaxWidth(),
                                    contentScale = ContentScale.Fit
                                )
                                Spacer(Modifier.height(8.dp))
                            }
                        }
                    }
                    document.mimeType.startsWith("image/") -> {
                        cachedFile?.let { file ->
                            val bitmap = remember(file) {
                                android.graphics.BitmapFactory.decodeFile(file.absolutePath)
                            }
                            bitmap?.let {
                                Image(
                                    bitmap = it.asImageBitmap(),
                                    contentDescription = null,
                                    modifier = Modifier.fillMaxWidth(),
                                    contentScale = ContentScale.Fit
                                )
                            }
                        }
                    }
                    else -> Text("Unsupported file type for preview")
                }
            }
        },
        confirmButton = {
            cachedFile?.let { file ->
                TextButton(onClick = {
                    openExternal(context, file, document.mimeType)
                }) {
                    Text("Open externally")
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        }
    )
}

private fun renderPdfToBitmaps(file: File): List<Bitmap> {
    val bitmaps = mutableListOf<Bitmap>()
    try {
        val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        PdfRenderer(fd).use { renderer ->
            val displayMetrics = android.content.res.Resources.getSystem().displayMetrics
            val screenWidth = displayMetrics.widthPixels
            for (i in 0 until renderer.pageCount) {
                renderer.openPage(i).use { page ->
                    val scale = screenWidth.toFloat() / page.width
                    val height = (page.height * scale).toInt()
                    val bitmap = Bitmap.createBitmap(screenWidth, height, Bitmap.Config.ARGB_8888)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    bitmaps.add(bitmap)
                }
            }
        }
    } catch (e: Exception) {
        e.printStackTrace()
    }
    return bitmaps
}

private fun openExternal(context: android.content.Context, file: File, mimeType: String) {
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
    val intent = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(uri, mimeType)
        flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK
    }
    context.startActivity(Intent.createChooser(intent, "Open with"))
}

// ── Tag Manager Dialog ───────────────────────────────────────────────────

@Composable
private fun TagManagerDialog(
    document: PapraDocument,
    settings: PapraSettings,
    api: PapraApiClient,
    onDismiss: () -> Unit,
    onUpdated: () -> Unit
) {
    val scope = rememberCoroutineScope()
    var allTags by remember { mutableStateOf<List<PapraTag>>(emptyList()) }
    var currentTagIds by remember { mutableStateOf(document.tags.map { it.id }.toSet()) }
    var isLoading by remember { mutableStateOf(true) }

    LaunchedEffect(Unit) {
        val result = api.listTags(settings.baseUrl, settings.apiKey, settings.organizationId)
        if (result is ApiResult.Success) allTags = result.data
        isLoading = false
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Manage tags") },
        text = {
            if (isLoading) {
                Box(Modifier.fillMaxWidth().height(60.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(modifier = Modifier.size(24.dp))
                }
            } else {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    allTags.forEach { tag ->
                        val selected = tag.id in currentTagIds
                        FilterChip(
                            selected = selected,
                            onClick = {
                                scope.launch {
                                    if (selected) {
                                        api.removeTagFromDocument(
                                            settings.baseUrl, settings.apiKey,
                                            settings.organizationId, document.id, tag.id
                                        )
                                        currentTagIds = currentTagIds - tag.id
                                    } else {
                                        api.addTagToDocument(
                                            settings.baseUrl, settings.apiKey,
                                            settings.organizationId, document.id, tag.id
                                        )
                                        currentTagIds = currentTagIds + tag.id
                                    }
                                    onUpdated()
                                }
                            },
                            label = { Text(tag.name) },
                            leadingIcon = if (selected) {
                                { Icon(Icons.Default.Check, null, modifier = Modifier.size(16.dp)) }
                            } else null
                        )
                    }
                }
            }
        },
        confirmButton = {
            Button(onClick = onDismiss) { Text("Done") }
        }
    )
}

// ── Create Tag Dialog ──────────────────────────────────────────────────────

@Composable
private fun CreateTagDialog(
    settings: PapraSettings,
    api: PapraApiClient,
    onDismiss: () -> Unit,
    onCreated: () -> Unit
) {
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf("") }
    var color by remember { mutableStateOf("#2563EB") }
    val presetColors = listOf(
        "#2563EB", "#DC2626", "#16A34A", "#CA8A04", "#9333EA",
        "#DB2777", "#0891B2", "#EA580C", "#4B5563", "#000000"
    )

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Create new tag") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Tag name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                Text("Color", style = MaterialTheme.typography.labelSmall)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    presetColors.forEach { c ->
                        val selected = c == color
                        Surface(
                            color = Color(android.graphics.Color.parseColor(c)),
                            shape = RoundedCornerShape(20.dp),
                            modifier = Modifier
                                .size(36.dp)
                                .clickable { color = c }
                                .then(if (selected) Modifier.padding(2.dp) else Modifier),
                            border = if (selected) {
                                androidx.compose.foundation.BorderStroke(2.dp, MaterialTheme.colorScheme.onSurface)
                            } else null
                        ) {
                            if (selected) {
                                Icon(Icons.Default.Check, null, tint = Color.White,
                                    modifier = Modifier.padding(6.dp))
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    if (name.isNotBlank()) {
                        scope.launch {
                            api.createTag(settings.baseUrl, settings.apiKey, settings.organizationId, name, color)
                            onCreated()
                            onDismiss()
                        }
                    }
                },
                enabled = name.isNotBlank()
            ) { Text("Create") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        }
    )
}
