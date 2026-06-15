package com.papra.app.ui.screens

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun UploadScreen(
    viewModel: UploadViewModel,
    onGoToSettings: () -> Unit
) {
    val state by viewModel.state.collectAsState()
    val snackbarHostState = remember { SnackbarHostState() }

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetMultipleContents()
    ) { uris: List<Uri> ->
        if (uris.isNotEmpty()) viewModel.addFiles(uris)
    }

    LaunchedEffect(state.snackbarMessage) {
        state.snackbarMessage?.let { msg ->
            snackbarHostState.showSnackbar(msg)
            viewModel.clearSnackbar()
        }
    }

    // Tag picker dialog
    if (state.tagPickerDocumentId != null) {
        TagPickerDialog(
            documentName = state.tagPickerDocumentName ?: "",
            tags = state.availableTags,
            selectedTagIds = state.selectedTagIds,
            isLoading = state.isLoadingTags,
            onToggleTag = { viewModel.toggleTag(it) },
            onConfirm = { viewModel.confirmTags() },
            onDismiss = { viewModel.dismissTagPicker() },
            onCreateTag = { viewModel.showCreateTag() }
        )
    }

    // Create tag dialog (shared between upload and tag picker)
    if (state.isCreatingTag) {
        CreateTagDialog(
            onDismiss = { viewModel.dismissCreateTag() },
            onCreate = { name, color -> viewModel.createTag(name, color) }
        )
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = { Text("Upload", fontWeight = FontWeight.SemiBold) },
                actions = {
                    if (state.files.isNotEmpty()) {
                        TextButton(onClick = { viewModel.clearAll() }) {
                            Text("Clear all")
                        }
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp)
        ) {
            // Offline banner
            if (state.isOffline) {
                Surface(
                    color = MaterialTheme.colorScheme.errorContainer,
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.padding(10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(Icons.Default.WifiOff, contentDescription = null,
                            tint = MaterialTheme.colorScheme.onErrorContainer)
                        Text("No internet connection",
                            color = MaterialTheme.colorScheme.onErrorContainer,
                            style = MaterialTheme.typography.bodySmall)
                    }
                }
                Spacer(Modifier.height(8.dp))
            }

            if (!state.settings.isConfigured) {
                ConfigWarningBanner(onGoToSettings)
                Spacer(Modifier.height(12.dp))
            }

            OutlinedButton(
                onClick = { filePicker.launch("*/*") },
                modifier = Modifier.fillMaxWidth(),
                contentPadding = PaddingValues(vertical = 14.dp)
            ) {
                Icon(Icons.Default.AttachFile, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Pick files")
            }

            Spacer(Modifier.height(12.dp))

            if (state.files.isEmpty()) {
                EmptyState()
            } else {
                LazyColumn(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    items(state.files, key = { it.uri.toString() }) { item ->
                        FileUploadCard(
                            item = item,
                            onRemove = { viewModel.removeFile(item.uri) },
                            onRetry = { viewModel.retryFile(item.uri) }
                        )
                    }
                }

                Spacer(Modifier.height(12.dp))

                val hasPending = state.files.any {
                    it.status == UploadStatus.PENDING || it.status == UploadStatus.FAILED
                }
                Button(
                    onClick = { viewModel.uploadAll() },
                    enabled = hasPending && !state.isUploading && state.settings.isConfigured,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 8.dp),
                    contentPadding = PaddingValues(vertical = 14.dp)
                ) {
                    if (state.isUploading) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            color = MaterialTheme.colorScheme.onPrimary,
                            strokeWidth = 2.dp
                        )
                        Spacer(Modifier.width(8.dp))
                        Text("Uploading...")
                    } else {
                        Icon(Icons.Default.CloudUpload, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        val count = state.files.count {
                            it.status == UploadStatus.PENDING || it.status == UploadStatus.FAILED
                        }
                        Text("Upload $count file(s)")
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TagPickerDialog(
    documentName: String,
    tags: List<PapraTag>,
    selectedTagIds: Set<String>,
    isLoading: Boolean,
    onToggleTag: (String) -> Unit,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    onCreateTag: () -> Unit
) {
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(16.dp),
            tonalElevation = 6.dp
        ) {
            Column(modifier = Modifier.padding(20.dp)) {
                Text("Tag document", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(4.dp))
                Text(documentName, style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.outline, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(16.dp))

                when {
                    isLoading -> {
                        Box(Modifier.fillMaxWidth().height(60.dp), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(modifier = Modifier.size(24.dp))
                        }
                    }
                    tags.isEmpty() -> {
                        Text("No tags found. Create one below.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.outline)
                    }
                    else -> {
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            tags.forEach { tag ->
                                val selected = tag.id in selectedTagIds
                                FilterChip(
                                    selected = selected,
                                    onClick = { onToggleTag(tag.id) },
                                    label = { Text(tag.name) },
                                    leadingIcon = if (selected) {
                                        { Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(16.dp)) }
                                    } else null
                                )
                            }
                        }
                    }
                }

                Spacer(Modifier.height(12.dp))
                TextButton(onClick = onCreateTag, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Default.Add, null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Create new tag")
                }

                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    TextButton(onClick = onDismiss, modifier = Modifier.weight(1f)) {
                        Text("Skip")
                    }
                    Button(onClick = onConfirm, modifier = Modifier.weight(1f)) {
                        Text(if (selectedTagIds.isEmpty()) "Done" else "Add ${selectedTagIds.size} tag(s)")
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CreateTagDialog(
    onDismiss: () -> Unit,
    onCreate: (String, String) -> Unit
) {
    var name by remember { mutableStateOf("") }
    var color by remember { mutableStateOf("#2563EB") }
    val presetColors = listOf(
        "#2563EB", "#DC2626", "#16A34A", "#CA8A04", "#9333EA",
        "#DB2777", "#0891B2", "#EA580C", "#4B5563", "#000000"
    )

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(16.dp),
            tonalElevation = 6.dp
        ) {
            Column(modifier = Modifier.padding(20.dp)) {
                Text("Create new tag", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(12.dp))

                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Tag name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                Spacer(Modifier.height(12.dp))
                Text("Color", style = MaterialTheme.typography.labelSmall)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    presetColors.forEach { c ->
                        val selected = c == color
                        Surface(
                            color = androidx.compose.ui.graphics.Color(android.graphics.Color.parseColor(c)),
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
                                Icon(Icons.Default.Check, null, tint = androidx.compose.ui.graphics.Color.White,
                                    modifier = Modifier.padding(6.dp))
                            }
                        }
                    }
                }

                Spacer(Modifier.height(20.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    TextButton(onClick = onDismiss, modifier = Modifier.weight(1f)) {
                        Text("Cancel")
                    }
                    Button(
                        onClick = { onCreate(name, color) },
                        enabled = name.isNotBlank(),
                        modifier = Modifier.weight(1f)
                    ) {
                        Text("Create")
                    }
                }
            }
        }
    }
}

@Composable
private fun ConfigWarningBanner(onGoToSettings: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.errorContainer,
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier.padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(Icons.Default.Warning, contentDescription = null,
                tint = MaterialTheme.colorScheme.onErrorContainer)
            Spacer(Modifier.width(8.dp))
            Text("Configure your Papra instance first",
                modifier = Modifier.weight(1f),
                color = MaterialTheme.colorScheme.onErrorContainer,
                style = MaterialTheme.typography.bodySmall)
            TextButton(onClick = onGoToSettings) { Text("Settings") }
        }
    }
}

@Composable
private fun EmptyState() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Default.CloudUpload, contentDescription = null,
                modifier = Modifier.size(56.dp),
                tint = MaterialTheme.colorScheme.outlineVariant)
            Spacer(Modifier.height(12.dp))
            Text("No files selected", style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.outline)
            Text("Tap 'Pick files' to get started", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outlineVariant)
        }
    }
}

@Composable
private fun FileUploadCard(
    item: FileUploadItem,
    onRemove: () -> Unit,
    onRetry: () -> Unit
) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        tonalElevation = 1.dp,
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = when (item.status) {
                        UploadStatus.DONE -> Icons.Default.CheckCircle
                        UploadStatus.FAILED -> Icons.Default.Error
                        UploadStatus.UPLOADING -> Icons.Default.CloudUpload
                        UploadStatus.PENDING -> Icons.Default.Description
                    },
                    contentDescription = null,
                    tint = when (item.status) {
                        UploadStatus.DONE -> MaterialTheme.colorScheme.primary
                        UploadStatus.FAILED -> MaterialTheme.colorScheme.error
                        else -> MaterialTheme.colorScheme.outline
                    },
                    modifier = Modifier.size(20.dp)
                )
                Spacer(Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(item.name, style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(formatSize(item.size), style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.outline)
                }
                when (item.status) {
                    UploadStatus.PENDING, UploadStatus.DONE -> {
                        IconButton(onClick = onRemove, modifier = Modifier.size(32.dp)) {
                            Icon(Icons.Default.Close, contentDescription = "Remove", modifier = Modifier.size(16.dp))
                        }
                    }
                    UploadStatus.FAILED -> {
                        IconButton(onClick = onRetry, modifier = Modifier.size(32.dp)) {
                            Icon(Icons.Default.Refresh, contentDescription = "Retry", modifier = Modifier.size(16.dp))
                        }
                    }
                    UploadStatus.UPLOADING -> {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                    }
                }
            }

            if (item.status == UploadStatus.UPLOADING) {
                Spacer(Modifier.height(8.dp))
                LinearProgressIndicator(
                    progress = { item.progress / 100f },
                    modifier = Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp))
                )
            }

            if (item.status == UploadStatus.FAILED && item.errorMessage != null) {
                Spacer(Modifier.height(4.dp))
                Text(item.errorMessage, style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

private fun formatSize(bytes: Long): String {
    if (bytes <= 0) return "unknown size"
    val kb = bytes / 1024.0
    val mb = kb / 1024.0
    return when {
        mb >= 1 -> "%.1f MB".format(mb)
        kb >= 1 -> "%.0f KB".format(kb)
        else -> "$bytes B"
    }
}
