package com.chuds.sensorrecorder.app

import android.graphics.Color
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import com.chuds.sensorrecorder.BuildConfig
import com.chuds.sensorrecorder.ui.RootView

class MainActivity : ComponentActivity() {
    private val model: AppModel get() = (application as BumpyApp).model

    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        model.onPermissionAnswer()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val bars = SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT) // dark icons, light theme only
        enableEdgeToEdge(bars, bars)
        if (BuildConfig.DEBUG) { // any app could pass extras to a released build and redirect its trips
            // iOS's launch arguments: adb shell am start -n … --es upload.baseURL … --es dashboard.baseURL …
            intent.getStringExtra("upload.baseURL")?.let { model.settings.baseUrlString = it }
            intent.getStringExtra("dashboard.baseURL")?.let { model.settings.dashboardOverride = it }
        }
        setContent {
            val recording = model.recording?.takeIf { !it.isFinished }
            LaunchedEffect(recording != null) {
                // The screen never locks while recording.
                if (recording != null) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            RootView(model)
        }
    }

    override fun onStart() {
        super.onStart()
        model.permissionPrompt = { permissions.launch(it.toTypedArray()) }
        model.onVisibilityChanged(visible = true)
    }

    override fun onStop() {
        model.permissionPrompt = null
        if (!isChangingConfigurations) model.onVisibilityChanged(visible = false)
        super.onStop()
    }
}
