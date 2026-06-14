package com.papra.app.data.datastore

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "papra_settings")

data class PapraSettings(
    val baseUrl: String = "",
    val apiKey: String = "",
    val organizationId: String = ""
) {
    val isConfigured get() = baseUrl.isNotBlank() && apiKey.isNotBlank() && organizationId.isNotBlank()
}

class SettingsRepository(private val context: Context) {

    companion object {
        private val KEY_BASE_URL = stringPreferencesKey("base_url")
        private val KEY_API_KEY = stringPreferencesKey("api_key")
        private val KEY_ORG_ID = stringPreferencesKey("organization_id")
    }

    val settings: Flow<PapraSettings> = context.dataStore.data.map { prefs ->
        PapraSettings(
            baseUrl = prefs[KEY_BASE_URL]?.trimEnd('/') ?: "",
            apiKey = prefs[KEY_API_KEY] ?: "",
            organizationId = prefs[KEY_ORG_ID] ?: ""
        )
    }

    suspend fun save(settings: PapraSettings) {
        context.dataStore.edit { prefs ->
            prefs[KEY_BASE_URL] = settings.baseUrl.trimEnd('/')
            prefs[KEY_API_KEY] = settings.apiKey
            prefs[KEY_ORG_ID] = settings.organizationId
        }
    }
}
