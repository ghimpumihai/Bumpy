package com.chuds.sensorrecorder.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.chuds.sensorrecorder.app.AppInfo
import com.chuds.sensorrecorder.app.AppModel
import com.chuds.sensorrecorder.upload.UploadConfig
import com.chuds.sensorrecorder.upload.UploadQueue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Upload settings (spec §6): API base URL + device key entered at runtime, never committed. */
@Composable
fun SettingsView(app: AppModel, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    var baseUrl by remember { mutableStateOf(app.settings.baseUrlString) }
    var deviceKey by remember { mutableStateOf(app.settings.deviceKey) }
    var test by remember { mutableStateOf<UploadQueue.ProbeResult?>(null) }
    var testing by remember { mutableStateOf(false) }
    var waitingTrips by remember { mutableStateOf(0) }
    var failedUploads by remember { mutableStateOf(0) }
    val usable = UploadConfig.parseBaseUrl(baseUrl) != null

    fun save() {
        app.settings.baseUrlString = baseUrl
        app.settings.deviceKey = deviceKey
        app.uploadQueue.kick()
    }

    fun runTest() {
        save()
        testing = true
        scope.launch {
            test = withContext(Dispatchers.IO) { UploadQueue.testConnection(app.settings.uploadConfig, app.settings.deviceId) }
            testing = false
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            focus.clearFocus()
            save()
        }
    }
    LaunchedEffect(Unit) {
        while (true) {
            // Directory listing: never on the main thread.
            val (trips, failed) = withContext(Dispatchers.IO) { app.uploadQueue.waitingTripCount() to app.uploadQueue.failedFiles().size }
            waitingTrips = trips
            failedUploads = failed
            delay(1000)
        }
    }

    Column(
        Modifier.fillMaxSize().background(Theme.background).safeArea().padding(horizontal = Theme.gutter).padding(bottom = 8.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            CircleIconButton(Icon.CHEVRON_LEFT, "Back", "settingsBack", Modifier.offset(x = (-4).dp), size = 34.dp, onClick = onBack)
            BasicText("Settings", style = Theme.font(24, FontWeight.SemiBold, tracking = -0.5))
        }
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            BasicText("Cloud", style = Theme.font(13, FontWeight.Medium, Theme.muted))
            Column {
                Hairline()
                Field("Server", baseUrl, "apiBaseURL", "your-app.azurewebsites.net") {
                    baseUrl = it
                    test = null
                }
                Field("Device key", deviceKey, "deviceKey", secure = true) {
                    deviceKey = it
                    test = null
                }
            }
            Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.alpha(if (usable) 1f else 0.4f).heightIn(min = 44.dp)
                        .border(1.dp, Theme.line, RoundedCornerShape(12.dp))
                        .plainButton("testConnection", enabled = usable && !testing, onClick = ::runTest)
                        .padding(horizontal = 16.dp),
                    contentAlignment = Alignment.Center,
                ) { BasicText("Test connection", style = Theme.font(15, FontWeight.SemiBold), maxLines = 1) }
                StatusText(baseUrl.isBlank(), usable, testing, test, waitingText(waitingTrips))
            }
            if (failedUploads > 0) {
                // Parts the server rejected (other 4xx) wait in upload_failed/; once the backend is fixed,
                // this sends them again, oldest first.
                Column(Modifier.padding(top = 8.dp)) {
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = 52.dp).plainButton("retryFailedUploads") {
                            failedUploads = 0
                            scope.launch(Dispatchers.IO) { app.uploadQueue.requeueFailed() }
                        },
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        BasicText("Retry failed uploads ($failedUploads)", Modifier.weight(1f), style = Theme.font(15, color = Theme.warn))
                        IconImage(Icon.ARROW_CLOCKWISE, 15.dp, Theme.warn, 1.6f)
                    }
                    Hairline()
                }
            }
        }
        Spacer(Modifier.weight(1f))
        BasicText("Version ${AppInfo.SHORT_VERSION} · ${AppInfo.modelName}", style = Theme.font(13, color = Theme.muted))
    }
}

private fun waitingText(trips: Int) = when (trips) {
    0 -> "nothing waiting"
    1 -> "1 trip waiting"
    else -> "$trips trips waiting"
}

/** Grey when fine; red with a dot when the test failed or the address can't be used. */
@Composable
private fun StatusText(empty: Boolean, usable: Boolean, testing: Boolean, test: UploadQueue.ProbeResult?, waiting: String) {
    val (text, problem) = when {
        empty -> "Upload off · $waiting" to false
        !usable -> "Use https://" to true
        testing -> "Checking…" to false
        test != null -> "${test.short} · $waiting" to !test.ok
        else -> waiting.replaceFirstChar { it.uppercase() } to false
    }
    Row(
        Modifier.testTag("connectionStatus").semantics(mergeDescendants = true) { },
        horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        if (problem) Dot(Theme.problem, 6.dp)
        BasicText(text, style = Theme.font(14, color = if (problem) Theme.problem else Theme.muted), maxLines = 2)
    }
}

@Composable
private fun Field(
    label: String,
    value: String,
    id: String,
    placeholder: String = "",
    secure: Boolean = false,
    onChange: (String) -> Unit,
) {
    Row(Modifier.fillMaxWidth().heightIn(min = 52.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        BasicText(label, Modifier.width(92.dp), style = Theme.font(15, color = Theme.muted))
        BasicTextField(
            value, onChange, Modifier.weight(1f).testTag(id),
            textStyle = Theme.font(15), singleLine = true, cursorBrush = SolidColor(Theme.ink),
            visualTransformation = if (secure) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false,
                keyboardType = if (secure) KeyboardType.Password else KeyboardType.Uri,
            ),
            decorationBox = { inner ->
                Box(Modifier.heightIn(min = 44.dp), contentAlignment = Alignment.CenterStart) {
                    if (value.isEmpty()) BasicText(placeholder, style = Theme.font(15, color = Theme.placeholder))
                    inner()
                }
            },
        )
    }
    Hairline()
}
