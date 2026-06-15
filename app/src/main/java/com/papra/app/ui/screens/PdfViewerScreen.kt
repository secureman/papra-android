package com.papra.app.ui.screens

import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.ZoomIn
import androidx.compose.material.icons.filled.ZoomOut
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PdfViewerScreen(
    filePath: String,
    documentName: String,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    var pages by remember { mutableStateOf<List<Bitmap>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var pageCount by remember { mutableStateOf(0) }
    var zoom by remember { mutableStateOf(1f) }

    LaunchedEffect(filePath) {
        withContext(Dispatchers.IO) {
            try {
                val file = File(filePath)
                val pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                val renderer = PdfRenderer(pfd)

                if (renderer.pageCount == 0) {
                    renderer.close()
                    pfd.close()
                    errorMessage = "PDF has no pages or could not be read"
                    isLoading = false
                    return@withContext
                }

                pageCount = renderer.pageCount
                val bitmaps = mutableListOf<Bitmap>()
                val screenWidth = context.resources.displayMetrics.widthPixels

                for (i in 0 until renderer.pageCount) {
                    val page = renderer.openPage(i)
                    val scale = screenWidth.toFloat() / page.width.coerceAtLeast(1)
                    val bitmapWidth = screenWidth
                    val bitmapHeight = (page.height * scale).toInt().coerceAtLeast(1)
                    val bitmap = Bitmap.createBitmap(bitmapWidth, bitmapHeight, Bitmap.Config.ARGB_8888)
                    bitmap.eraseColor(android.graphics.Color.WHITE)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    page.close()
                    bitmaps.add(bitmap)
                }
                renderer.close()
                pfd.close()

                if (bitmaps.isEmpty()) {
                    errorMessage = "Could not render any pages"
                } else {
                    pages = bitmaps
                }
            } catch (e: SecurityException) {
                errorMessage = "PDF is password protected"
            } catch (e: Exception) {
                errorMessage = "Cannot render this PDF: ${e.message}"
            } finally {
                isLoading = false
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back")
                    }
                },
                title = {
                    Column {
                        Text(documentName, fontWeight = FontWeight.SemiBold,
                            maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                        if (pageCount > 0) {
                            Text("$pageCount page(s)", style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.outline)
                        }
                    }
                },
                actions = {
                    IconButton(onClick = { zoom = (zoom - 0.25f).coerceAtLeast(0.5f) }) {
                        Icon(Icons.Default.ZoomOut, contentDescription = "Zoom out")
                    }
                    IconButton(onClick = { zoom = (zoom + 0.25f).coerceAtMost(3f) }) {
                        Icon(Icons.Default.ZoomIn, contentDescription = "Zoom in")
                    }
                }
            )
        }
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .background(Color(0xFF2D2D2D))
        ) {
            when {
                isLoading -> {
                    Column(
                        modifier = Modifier.align(Alignment.Center),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        CircularProgressIndicator(color = Color.White)
                        Text("Rendering PDF...", color = Color.White,
                            style = MaterialTheme.typography.bodySmall)
                    }
                }
                errorMessage != null -> {
                    Column(
                        modifier = Modifier.align(Alignment.Center).padding(32.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(16.dp)
                    ) {
                        Text(errorMessage ?: "Error", color = Color.White,
                            style = MaterialTheme.typography.bodyMedium)
                        OutlinedButton(
                            onClick = {
                                val file = java.io.File(filePath)
                                val uri = androidx.core.content.FileProvider.getUriForFile(
                                    context, "${context.packageName}.fileprovider", file
                                )
                                val intent = android.content.Intent(android.content.Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, "application/pdf")
                                    addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                context.startActivity(android.content.Intent.createChooser(intent, "Open with"))
                            }
                        ) {
                            Text("Open with external app", color = Color.White)
                        }
                    }
                }
                pages.isEmpty() -> {
                    Text("No pages found", color = Color.White,
                        modifier = Modifier.align(Alignment.Center))
                }
                else -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(vertical = 8.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        itemsIndexed(pages) { index, bitmap ->
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 8.dp)
                            ) {
                                Image(
                                    bitmap = bitmap.asImageBitmap(),
                                    contentDescription = "Page ${index + 1}",
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .graphicsLayer(scaleX = zoom, scaleY = zoom),
                                    contentScale = ContentScale.FillWidth
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
