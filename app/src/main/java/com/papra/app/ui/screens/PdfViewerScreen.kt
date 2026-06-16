package com.papra.app.ui.screens

import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
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
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import java.io.File

/**
 * FIX #2: Lazy PDF page rendering.
 *
 * BEFORE: All pages were rendered upfront into a List<Bitmap> held in memory for the
 * lifetime of the screen. A 100-page A4 PDF at screen width ~1080px easily OOMs.
 *
 * AFTER:
 * - PdfRenderer + ParcelFileDescriptor are opened once and kept alive via DisposableEffect.
 * - LazyColumn renders one item per page index (integers, not bitmaps).
 * - Each item renders its own bitmap on-demand in a LaunchedEffect(pageIndex).
 * - When the item leaves composition its DisposableEffect recycles the bitmap immediately.
 * - At any given moment only visible pages (±compose buffer) are in memory.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PdfViewerScreen(
    filePath: String,
    documentName: String,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val screenWidth = context.resources.displayMetrics.widthPixels

    // Holds the open renderer; null until the file is ready or if open failed.
    var renderer by remember { mutableStateOf<PdfRenderer?>(null) }
    var pfd by remember { mutableStateOf<ParcelFileDescriptor?>(null) }
    var pageCount by remember { mutableStateOf(0) }
    var isLoading by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var zoom by remember { mutableStateOf(1f) }

    // Open the renderer once; close it when the composable leaves the tree.
    DisposableEffect(filePath) {
        try {
            val file = File(filePath)
            val openedPfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            val openedRenderer = PdfRenderer(openedPfd)
            if (openedRenderer.pageCount == 0) {
                openedRenderer.close()
                openedPfd.close()
                errorMessage = "PDF has no pages or could not be read"
            } else {
                pfd = openedPfd
                renderer = openedRenderer
                pageCount = openedRenderer.pageCount
            }
        } catch (e: SecurityException) {
            errorMessage = "PDF is password protected"
        } catch (e: Exception) {
            errorMessage = "Cannot open this PDF: ${e.message}"
        } finally {
            isLoading = false
        }

        onDispose {
            renderer?.close()
            pfd?.close()
            renderer = null
            pfd = null
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
                        Text(
                            documentName,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                        )
                        if (pageCount > 0) {
                            Text(
                                "$pageCount page(s)",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.outline
                            )
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
                        Text(
                            "Opening PDF…",
                            color = Color.White,
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                }

                errorMessage != null -> {
                    Column(
                        modifier = Modifier
                            .align(Alignment.Center)
                            .padding(32.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(16.dp)
                    ) {
                        Text(
                            errorMessage ?: "Error",
                            color = Color.White,
                            style = MaterialTheme.typography.bodyMedium
                        )
                        OutlinedButton(
                            onClick = {
                                val file = File(filePath)
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

                pageCount == 0 -> {
                    Text(
                        "No pages found",
                        color = Color.White,
                        modifier = Modifier.align(Alignment.Center)
                    )
                }

                else -> {
                    val listState = rememberLazyListState()
                    LazyColumn(
                        state = listState,
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(vertical = 8.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        items(
                            count = pageCount,
                            key = { pageIndex -> pageIndex }
                        ) { pageIndex ->
                            PdfPageItem(
                                pageIndex = pageIndex,
                                renderer = renderer,
                                screenWidth = screenWidth,
                                zoom = zoom
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * Renders a single PDF page lazily.
 *
 * - The bitmap is created on the IO dispatcher only when this item enters composition.
 * - The DisposableEffect recycles it when the item scrolls out of the compose tree,
 *   releasing native memory immediately rather than waiting for GC.
 * - A coroutine cancellation check (isActive) prevents writing to a recycled bitmap
 *   if the item leaves composition mid-render.
 */
@Composable
private fun PdfPageItem(
    pageIndex: Int,
    renderer: PdfRenderer?,
    screenWidth: Int,
    zoom: Float
) {
    var bitmap by remember { mutableStateOf<Bitmap?>(null) }
    var isRendering by remember { mutableStateOf(true) }

    // Render on IO; automatically cancels if the item leaves composition.
    LaunchedEffect(pageIndex, renderer) {
        if (renderer == null) { isRendering = false; return@LaunchedEffect }
        isRendering = true
        val rendered = withContext(Dispatchers.IO) {
            try {
                // PdfRenderer is not thread-safe — synchronize on the renderer instance
                // so concurrent page renders (e.g. fast scrolling) don't race.
                synchronized(renderer) {
                    if (!isActive) return@withContext null
                    val page = renderer.openPage(pageIndex)
                    val scale = screenWidth.toFloat() / page.width.coerceAtLeast(1)
                    val bw = screenWidth
                    val bh = (page.height * scale).toInt().coerceAtLeast(1)
                    val bmp = Bitmap.createBitmap(bw, bh, Bitmap.Config.ARGB_8888)
                    bmp.eraseColor(android.graphics.Color.WHITE)
                    page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    page.close()
                    bmp
                }
            } catch (_: Exception) {
                null
            }
        }
        bitmap = rendered
        isRendering = false
    }

    // Recycle the bitmap when the item scrolls out of composition.
    DisposableEffect(pageIndex) {
        onDispose {
            bitmap?.recycle()
            bitmap = null
        }
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp),
        contentAlignment = Alignment.Center
    ) {
        val bmp = bitmap
        if (isRendering || bmp == null) {
            // Placeholder keeps the list from collapsing while the page renders.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(0.707f) // approximate A4 ratio
                    .background(Color(0xFF3A3A3A)),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(24.dp))
            }
        } else {
            Image(
                bitmap = bmp.asImageBitmap(),
                contentDescription = "Page ${pageIndex + 1}",
                modifier = Modifier
                    .fillMaxWidth()
                    .graphicsLayer(scaleX = zoom, scaleY = zoom),
                contentScale = ContentScale.FillWidth
            )
        }
    }
}
