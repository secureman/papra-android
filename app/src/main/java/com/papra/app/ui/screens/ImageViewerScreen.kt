package com.papra.app.ui.screens

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
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
import androidx.compose.ui.text.style.TextOverflow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Maximum dimension (width or height) allowed for the decoded bitmap in pixels.
 * Images larger than this are downsampled via inSampleSize before decoding.
 * 2048px comfortably covers any phone screen while staying well within heap limits.
 */
private const val MAX_IMAGE_DIMENSION = 2048

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImageViewerScreen(
    filePath: String,
    documentName: String,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    var bitmap by remember { mutableStateOf<Bitmap?>(null) }
    var isLoading by remember { mutableStateOf(true) }
    var scale by remember { mutableStateOf(1f) }
    var offsetX by remember { mutableStateOf(0f) }
    var offsetY by remember { mutableStateOf(0f) }

    LaunchedEffect(filePath) {
        withContext(Dispatchers.IO) {
            // FIX #3: Downsample large images before decoding to prevent OOM.
            //
            // Step 1 — decode only bounds (no pixel memory allocated).
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(filePath, options)

            // Step 2 — calculate the largest inSampleSize that keeps both dimensions
            //           within MAX_IMAGE_DIMENSION.
            options.inSampleSize = calculateInSampleSize(
                srcWidth = options.outWidth,
                srcHeight = options.outHeight,
                maxDimension = MAX_IMAGE_DIMENSION
            )

            // Step 3 — decode with downsampling applied.
            options.inJustDecodeBounds = false
            bitmap = BitmapFactory.decodeFile(filePath, options)
        }
        isLoading = false
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
                    Text(
                        documentName,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Color.Black.copy(alpha = 0.7f),
                    titleContentColor = Color.White,
                    navigationIconContentColor = Color.White
                )
            )
        }
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .background(Color.Black),
            contentAlignment = Alignment.Center
        ) {
            when {
                isLoading -> CircularProgressIndicator(color = Color.White)
                bitmap == null -> Text("Failed to load image", color = Color.White)
                else -> Image(
                    bitmap = bitmap!!.asImageBitmap(),
                    contentDescription = documentName,
                    modifier = Modifier
                        .fillMaxSize()
                        .pointerInput(Unit) {
                            detectTransformGestures { _, pan, zoom, _ ->
                                scale = (scale * zoom).coerceIn(0.5f, 5f)
                                offsetX += pan.x
                                offsetY += pan.y
                            }
                        }
                        .graphicsLayer(
                            scaleX = scale,
                            scaleY = scale,
                            translationX = offsetX,
                            translationY = offsetY
                        ),
                    contentScale = ContentScale.Fit
                )
            }
        }
    }
}

/**
 * Returns the largest power-of-two inSampleSize such that both the downsampled
 * width and height remain ≤ [maxDimension].
 *
 * Example: 4000×3000 image with maxDimension=2048
 *   → inSampleSize=2 → decoded size 2000×1500 ✓
 */
private fun calculateInSampleSize(srcWidth: Int, srcHeight: Int, maxDimension: Int): Int {
    if (srcWidth <= 0 || srcHeight <= 0) return 1
    var sampleSize = 1
    while (
        (srcWidth / (sampleSize * 2)) >= maxDimension ||
        (srcHeight / (sampleSize * 2)) >= maxDimension
    ) {
        sampleSize *= 2
    }
    return sampleSize
}
