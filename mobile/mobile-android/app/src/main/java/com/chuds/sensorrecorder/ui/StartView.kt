package com.chuds.sensorrecorder.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.chuds.sensorrecorder.app.AppModel
import com.chuds.sensorrecorder.core.text
import com.chuds.sensorrecorder.recording.PreflightModel
import com.chuds.sensorrecorder.recording.PreflightModel.Check
import com.chuds.sensorrecorder.recording.PreflightModel.Status

/**
 * Start: nothing to fill in. The preflight checks run silently; only one that isn't passing shows, as one
 * line with its fix. Start with a failing check needs a confirm (recorded as an override).
 */
@Composable
fun StartView(app: AppModel, openMenu: () -> Unit) {
    val model = app.preflight
    var confirmOverride by remember { mutableStateOf(false) }
    var startError by remember { mutableStateOf<String?>(null) }
    var startAfterCheck by remember { mutableStateOf(false) }

    fun begin(overridden: Boolean) {
        if (model.busy) return
        val result = model.result(overridden)
        model.onDisappear() // the recording takes over motion and location
        try {
            app.startRecording(result)
        } catch (e: Exception) {
            startError = e.text
            model.onAppear()
        }
    }

    fun start() {
        if (model.busy) return
        val failing = model.failingRequired
        when {
            failing.isEmpty() -> begin(overridden = false)
            // The stillness test first runs when the app opens, usually with the phone still in hand. Once
            // it's mounted, Start re-runs the 5 s motion check before offering the override.
            failing.all { it.id.startsWith("motion.") } -> {
                startAfterCheck = true
                model.rerunMotionTest()
            }
            else -> confirmOverride = true
        }
    }

    val idle = app.recording == null
    var wasRecording by remember { mutableStateOf(!idle) }
    DisposableEffect(idle) {
        if (idle) {
            model.onAppear()
            if (wasRecording) model.rerun() // the old results are stale (battery, GPS, motion test)
        }
        wasRecording = !idle
        onDispose { if (app.recording == null) model.onDisappear() }
    }
    LaunchedEffect(model.busy) {
        if (!model.busy && startAfterCheck) {
            startAfterCheck = false
            if (model.allRequiredPass) begin(overridden = false) else confirmOverride = true
        }
    }

    Column(
        Modifier.fillMaxSize().background(Theme.background).safeArea().padding(horizontal = Theme.gutter).padding(bottom = 8.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        CircleIconButton(Icon.MENU, "Menu", "menuButton", Modifier.offset(x = (-4).dp), onClick = openMenu)
        Spacer(Modifier.weight(1f))
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Headline(listOf("Ready", "to ride"), Modifier.riseIn(0.08))
            BasicText(
                "Lay the phone flat, screen up, and don't move it. The sensors do the rest.",
                Modifier.widthIn(max = 300.dp).riseIn(0.16),
                style = Theme.font(17, color = Theme.muted, lineHeight = 24),
            )
            if (app.lastRecoveredCount > 0) {
                BasicText(
                    "${app.lastRecoveredCount} interrupted trip(s) were recovered. Their data is kept.",
                    Modifier.padding(top = 8.dp), style = Theme.font(14, color = Theme.muted),
                )
            }
        }
        Spacer(Modifier.weight(1f))
        Column(Modifier.riseIn(0.24), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            CheckLine(app, model)
            PrimaryButton(if (model.busy) "Checking…" else "Start trip", "startTrip", enabled = !model.busy) { start() }
        }
    }

    if (confirmOverride) {
        AlertBox(
            "Start with a failing check?",
            model.failingRequired.joinToString("\n") { "• ${it.title}: ${it.detail}" } + "\n\nThe override is recorded with the trip.",
            cancel = "Cancel", confirm = "Start anyway", confirmId = "confirmOverride", destructive = true,
            onCancel = { confirmOverride = false },
        ) {
            confirmOverride = false
            begin(overridden = true)
        }
    }
    startError?.let { e ->
        AlertBox("Could not start", e, cancel = null, confirm = "OK", confirmId = "startErrorOk", onCancel = { startError = null }) {
            startError = null
        }
    }
}

/** The first required check that isn't passing: grey while it is still running, red when it failed. */
@Composable
private fun CheckLine(app: AppModel, model: PreflightModel) {
    val context = LocalContext.current
    val failing = model.failingRequired
    val check = failing.firstOrNull { it.status == Status.FAIL } ?: (if (model.busy) null else failing.firstOrNull()) ?: return
    val failed = check.status == Status.FAIL
    val color = if (failed) Theme.problem else Theme.muted
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        Dot(color, 8.dp)
        BasicText(headline(check), Modifier.weight(1f).testTag("checkLine"), style = Theme.font(15, color = color))
        val fix = if (failed) fix(context, app, check, model) else null
        if (fix != null) {
            Box(Modifier.heightIn(min = 44.dp).plainButton("fixCheck", onClick = fix.second), contentAlignment = Alignment.Center) {
                BasicText(fix.first, style = Theme.font(15, FontWeight.SemiBold, color).copy(textDecoration = TextDecoration.Underline))
            }
        }
    }
}

private fun headline(c: Check): String = if (c.status != Status.FAIL) {
    if (c.id == "gps.fix") "Waiting for a precise GPS fix…" else "Checking ${c.title.lowercase()}…"
} else when (c.id) {
    "perm.location" -> if (c.detail.contains("Precise")) "Precise location is off" else "Location access is off"
    "perm.motion" -> "Motion access is off"
    "avail.motion", "avail.baro" -> "This phone lacks a needed sensor"
    "gps.fix" -> "No precise GPS fix yet"
    "motion.rate" -> "Motion sensors are too slow"
    "motion.still" -> "The phone moved during the check"
    "dev.lpm" -> "Battery Saver is on"
    "dev.battery" -> "Battery low: plug the phone in"
    "dev.thermal" -> "The phone is too hot"
    "dev.disk" -> "Not enough free space"
    else -> c.title
}

private fun fix(context: Context, app: AppModel, c: Check, model: PreflightModel): Pair<String, () -> Unit>? = when {
    c.id.startsWith("perm.") || c.id == "dev.lpm" -> "Fix" to {
        val intent = when {
            c.id == "dev.lpm" -> Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
            app.location.hasPermission && !app.location.isLocationOn -> Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
            else -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
        }
        runCatching { context.startActivity(intent) }
        Unit
    }
    c.id.startsWith("motion.") -> "Check again" to { model.rerunMotionTest() }
    c.id.startsWith("avail.") -> null
    else -> "Check again" to { model.rerun() }
}

/** An iOS-style alert. */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
internal fun AlertBox(
    title: String,
    message: String,
    cancel: String?,
    confirm: String,
    confirmId: String,
    destructive: Boolean = false,
    onCancel: () -> Unit,
    onConfirm: () -> Unit,
) {
    Dialog(onDismissRequest = onCancel) {
        // A dialog is its own window, so RootView's setting doesn't reach it.
        Column(Modifier.width(270.dp).background(Color(0xFFF7F7F7), RoundedCornerShape(14.dp)).semantics { testTagsAsResourceId = true }) {
            Column(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 20.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp), horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                BasicText(title, style = Theme.font(17, FontWeight.SemiBold).copy(textAlign = TextAlign.Center))
                BasicText(message, style = Theme.font(13).copy(textAlign = TextAlign.Center))
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
            Row(Modifier.fillMaxWidth().height(44.dp)) {
                if (cancel != null) {
                    AlertButton(cancel, "cancelAlert", Theme.ink, FontWeight.SemiBold, Modifier.weight(1f), onCancel)
                    Box(Modifier.width(1.dp).fillMaxHeight().background(Theme.line))
                }
                AlertButton(
                    confirm, confirmId, if (destructive) Theme.problem else Theme.ink,
                    if (cancel == null) FontWeight.SemiBold else FontWeight.Normal, Modifier.weight(1f), onConfirm,
                )
            }
        }
    }
}

@Composable
private fun AlertButton(text: String, id: String, color: Color, weight: FontWeight, modifier: Modifier, onClick: () -> Unit) {
    Box(modifier.fillMaxHeight().plainButton(id, onClick = onClick), contentAlignment = Alignment.Center) {
        BasicText(text, style = Theme.font(17, weight, color))
    }
}
