package com.papra.app.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.papra.app.data.api.ApiResult
import com.papra.app.data.api.PapraApiClient
import com.papra.app.data.datastore.PapraSettings
import com.papra.app.data.datastore.SettingsRepository
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen() {
    val context = LocalContext.current
    val api = remember { PapraApiClient(context) }
    val repo = remember { SettingsRepository(context) }
    val scope = rememberCoroutineScope()

    var baseUrl by remember { mutableStateOf("") }
    var apiKey by remember { mutableStateOf("") }
    var organizationId by remember { mutableStateOf("") }
    var apiKeyVisible by remember { mutableStateOf(false) }
    var isSaving by remember { mutableStateOf(false) }
    var isTesting by remember { mutableStateOf(false) }
    var testResult by remember { mutableStateOf<Boolean?>(null) }
    var testMessage by remember { mutableStateOf("") }
    var saved by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        val s = repo.settings.first()
        baseUrl = s.baseUrl
        apiKey = s.apiKey
        organizationId = s.organizationId
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings", fontWeight = FontWeight.SemiBold) }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Spacer(Modifier.height(4.dp))

            Text(
                "Papra Instance",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.primary
            )

            OutlinedTextField(
                value = baseUrl,
                onValueChange = { baseUrl = it; saved = false; testResult = null },
                label = { Text("Base URL") },
                placeholder = { Text("https://papra.app or http://192.168.1.x:3000") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri)
            )

            OutlinedTextField(
                value = apiKey,
                onValueChange = { apiKey = it; saved = false; testResult = null },
                label = { Text("API Key") },
                placeholder = { Text("pk_…") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                visualTransformation = if (apiKeyVisible)
                    VisualTransformation.None else PasswordVisualTransformation(),
                trailingIcon = {
                    IconButton(onClick = { apiKeyVisible = !apiKeyVisible }) {
                        Icon(
                            if (apiKeyVisible) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                            contentDescription = if (apiKeyVisible) "Hide" else "Show"
                        )
                    }
                }
            )

            OutlinedTextField(
                value = organizationId,
                onValueChange = { organizationId = it; saved = false },
                label = { Text("Organization ID") },
                placeholder = { Text("org_…") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            // Test result feedback
            if (testResult != null) {
                Surface(
                    color = if (testResult == true)
                        MaterialTheme.colorScheme.primaryContainer
                    else
                        MaterialTheme.colorScheme.errorContainer,
                    shape = MaterialTheme.shapes.small,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.padding(10.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(
                            if (testResult == true) Icons.Default.CheckCircle else Icons.Default.Error,
                            contentDescription = null,
                            tint = if (testResult == true)
                                MaterialTheme.colorScheme.onPrimaryContainer
                            else
                                MaterialTheme.colorScheme.onErrorContainer
                        )
                        Text(
                            testMessage,
                            color = if (testResult == true)
                                MaterialTheme.colorScheme.onPrimaryContainer
                            else
                                MaterialTheme.colorScheme.onErrorContainer,
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(
                    onClick = {
                        scope.launch {
                            isTesting = true
                            testResult = null
                            val url = baseUrl.trimEnd('/')
                            val result = api.testConnection(url, apiKey)
                            testResult = result is ApiResult.Success
                            testMessage = when (result) {
                                is ApiResult.Success -> "Connection successful ✓"
                                is ApiResult.Error -> "Failed: ${result.message}"
                                is ApiResult.NetworkError -> "Network error: ${result.message}"
                            }
                            isTesting = false
                        }
                    },
                    enabled = baseUrl.isNotBlank() && apiKey.isNotBlank() && !isTesting,
                    modifier = Modifier.weight(1f)
                ) {
                    if (isTesting) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    } else {
                        Text("Test connection")
                    }
                }

                Button(
                    onClick = {
                        scope.launch {
                            isSaving = true
                            repo.save(PapraSettings(baseUrl.trim(), apiKey.trim(), organizationId.trim()))
                            isSaving = false
                            saved = true
                        }
                    },
                    enabled = baseUrl.isNotBlank() && apiKey.isNotBlank() && organizationId.isNotBlank() && !isSaving,
                    modifier = Modifier.weight(1f)
                ) {
                    Text(if (saved) "Saved ✓" else "Save")
                }
            }

            Spacer(Modifier.height(8.dp))
            HorizontalDivider()
            Spacer(Modifier.height(4.dp))

            Text(
                "Tip: Find your Organization ID in Papra under Settings → Organization. Generate an API key under Settings → API Keys.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outline
            )
        }
    }
}
