package com.papra.app.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Settings
import androidx.compose.ui.graphics.vector.ImageVector

sealed class Screen(val route: String, val label: String, val icon: ImageVector) {
    object Upload : Screen("upload", "Upload", Icons.Default.CloudUpload)
    object Documents : Screen("documents", "Documents", Icons.Default.Description)
    object Settings : Screen("settings", "Settings", Icons.Default.Settings)

    companion object {
        val bottomNavItems = listOf(Upload, Documents, Settings)
    }
}
