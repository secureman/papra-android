package com.papra.app.ui.screens

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.papra.app.data.PapraApi
import com.papra.app.data.SettingsRepository

class UploadViewModelFactory(
    private val api: PapraApi,
    private val settings: SettingsRepository
) : ViewModelProvider.Factory {

    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        if (modelClass.isAssignableFrom(UploadViewModel::class.java)) {
            @Suppress("UNCHECKED_CAST")
            return UploadViewModel(api, settings) as T
        }
        throw IllegalArgumentException("Unknown ViewModel class")
    }
}
