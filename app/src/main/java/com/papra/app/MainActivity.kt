package com.papra.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.papra.app.navigation.Screen
import com.papra.app.navigation.ViewerScreen
import com.papra.app.ui.screens.*
import com.papra.app.ui.theme.PapraTheme
import java.net.URLDecoder

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        // NOTE: No cache cleanup here. Android's own cacheDir eviction handles stale files,
        // and an aggressive per-onCreate wipe was deleting files out from under the viewers
        // on configuration changes (rotation, theme, font scale), causing
        // "Failed to open document" / blank PDF/image errors. Cache trimming is now done
        // by trimPapraCache() invoked *after* a successful download in PapraApiClient.

        // FIX #16: Replace deprecated getParcelableExtra / getParcelableArrayListExtra with
        // the API 33+ typed overloads. The @Suppress fallback is intentional for API < 33.
        val sharedUris = mutableListOf<Uri>()
        when (intent?.action) {
            Intent.ACTION_SEND -> {
                val uri: Uri? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                uri?.let { sharedUris.add(it) }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris: ArrayList<Uri>? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                uris?.let { sharedUris.addAll(it) }
            }
        }

        setContent {
            PapraTheme { PapraApp(initialSharedUris = sharedUris) }
        }
    }
}

@Composable
fun PapraApp(initialSharedUris: List<Uri> = emptyList()) {
    val context = LocalContext.current
    val navController = rememberNavController()
    val uploadViewModel: UploadViewModel = viewModel(
        factory = ViewModelProvider.AndroidViewModelFactory(context.applicationContext as android.app.Application)
    )

    LaunchedEffect(initialSharedUris) {
        if (initialSharedUris.isNotEmpty()) {
            uploadViewModel.addFiles(initialSharedUris)
            navController.navigate(Screen.Upload.route) {
                popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                launchSingleTop = true; restoreState = true
            }
        }
    }

    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = navBackStackEntry?.destination?.route
    val showBottomBar = currentRoute in Screen.bottomNavItems.map { it.route }

    Scaffold(
        bottomBar = {
            if (showBottomBar) {
                NavigationBar {
                    Screen.bottomNavItems.forEach { screen ->
                        NavigationBarItem(
                            selected = currentRoute == screen.route,
                            onClick = {
                                navController.navigate(screen.route) {
                                    popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                                    launchSingleTop = true; restoreState = true
                                }
                            },
                            icon = { Icon(screen.icon, contentDescription = screen.label) },
                            label = { Text(screen.label) }
                        )
                    }
                }
            }
        }
    ) { innerPadding ->
        NavHost(
            navController = navController,
            startDestination = Screen.Upload.route,
            modifier = Modifier.padding(innerPadding)
        ) {
            composable(Screen.Upload.route) {
                UploadScreen(
                    viewModel = uploadViewModel,
                    onGoToSettings = { navController.navigate(Screen.Settings.route) { launchSingleTop = true } }
                )
            }
            composable(Screen.Documents.route) {
                DocumentsScreen(
                    onOpenPdf = { filePath, name ->
                        navController.navigate(ViewerScreen.Pdf.createRoute(filePath, name))
                    },
                    onOpenImage = { filePath, name ->
                        navController.navigate(ViewerScreen.Image.createRoute(filePath, name))
                    }
                )
            }
            composable(Screen.Settings.route) { SettingsScreen() }

            composable(ViewerScreen.Pdf.route) { backStackEntry ->
                val filePath = URLDecoder.decode(backStackEntry.arguments?.getString("filePath") ?: "", "UTF-8")
                val name = URLDecoder.decode(backStackEntry.arguments?.getString("documentName") ?: "", "UTF-8")
                PdfViewerScreen(filePath = filePath, documentName = name, onBack = { navController.popBackStack() })
            }
            composable(ViewerScreen.Image.route) { backStackEntry ->
                val filePath = URLDecoder.decode(backStackEntry.arguments?.getString("filePath") ?: "", "UTF-8")
                val name = URLDecoder.decode(backStackEntry.arguments?.getString("documentName") ?: "", "UTF-8")
                ImageViewerScreen(filePath = filePath, documentName = name, onBack = { navController.popBackStack() })
            }
        }
    }
}
