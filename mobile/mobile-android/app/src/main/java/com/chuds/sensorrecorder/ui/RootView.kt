package com.chuds.sensorrecorder.ui

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.chuds.sensorrecorder.app.AppInfo
import com.chuds.sensorrecorder.app.AppModel
import com.chuds.sensorrecorder.recording.RecordingController

/** Start → (cover) Recording → Recap. The burger menu and Settings are reachable from every screen. */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun RootView(app: AppModel) {
    Box(Modifier.fillMaxSize().background(Theme.background).semantics { testTagsAsResourceId = true }) {
        WithMenu(app) { openMenu -> StartView(app, openMenu) }
        val current = app.recording
        var last by remember { mutableStateOf<RecordingController?>(null) } // still drawn while the cover slides away
        if (current != null) last = current
        AnimatedVisibility(
            current != null,
            enter = slideInVertically(tween(400)) { it }, exit = slideOutVertically(tween(350)) { it },
        ) {
            last?.let { RecordingFlowView(app, it) }
        }
    }
}

/** Recording while it runs, the recap after Stop. */
@Composable
private fun RecordingFlowView(app: AppModel, controller: RecordingController) {
    BackHandler { } // nothing but the 2 s hold ends a trip, and nothing but Done leaves the recap
    WithMenu(app) { openMenu ->
        AnimatedContent(
            controller.finished,
            transitionSpec = {
                (fadeIn(tween(400)) + slideInVertically(Theme.spring(0.5, 0.9f)) { it / 50 })
                    .togetherWith(fadeOut(tween(250)) + slideOutVertically(tween(250)) { it / 50 })
            },
            modifier = Modifier.fillMaxSize().background(Theme.background), label = "flow",
        ) { meta ->
            if (meta != null) {
                RecapView(app, meta, controller.trackPoints, openMenu) { app.closeRecording() }
            } else {
                // The navigation bar stays: hiding it makes Android cover the screen with a "Got it" notice.
                RecordingView(controller, openMenu) { app.stopRecording() }
            }
        }
    }
}

/** Padding for the status bar, cutout and navigation bar, not for the keyboard: footers stay at the bottom. */
@Composable
fun Modifier.safeArea(): Modifier = windowInsetsPadding(WindowInsets.systemBars.union(WindowInsets.displayCutout))

/** A screen with the burger menu over it and Settings pushed from the right. */
@Composable
private fun WithMenu(app: AppModel, content: @Composable (openMenu: () -> Unit) -> Unit) {
    var menuOpen by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    val push by animateFloatAsState(if (showSettings) 1f else 0f, Theme.spring(0.45, 1f), label = "push")
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().graphicsLayer { translationX = -0.3f * push * size.width }) { content { menuOpen = true } }
        if (push > 0.001f || showSettings) {
            Box(
                Modifier.fillMaxSize().graphicsLayer { translationX = (1 - push) * size.width }.background(Theme.background)
                    .clickable(remember { MutableInteractionSource() }, null) { },
            ) { SettingsView(app) { showSettings = false } }
        }
        MenuDrawer(app, menuOpen, onClose = { menuOpen = false }) { showSettings = true }
    }
    BackHandler(showSettings) { showSettings = false }
    BackHandler(menuOpen) { menuOpen = false }
}

/** The burger menu: a panel from the left over a dimmed screen. Nothing in it can stop a trip. */
@Composable
private fun MenuDrawer(app: AppModel, open: Boolean, onClose: () -> Unit, onSettings: () -> Unit) {
    val x by animateDpAsState(if (open) 0.dp else (-330).dp, Theme.spring(0.45, 0.9f), label = "drawer")
    val dim by animateFloatAsState(if (open) 1f else 0f, Theme.spring(0.45, 0.9f), label = "scrim")
    if (!open && dim <= 0.001f && x <= (-329).dp) return
    val context = LocalContext.current
    Box(Modifier.fillMaxSize()) {
        Box(
            Modifier.fillMaxSize().graphicsLayer { alpha = dim.coerceIn(0f, 1f) }.background(Theme.scrim).then(
                if (open) Modifier.clickable(remember { MutableInteractionSource() }, null, onClick = onClose)
                else Modifier,
            ),
        )
        val shape = RoundedCornerShape(topEnd = 28.dp, bottomEnd = 28.dp)
        Column(
            Modifier.offset { IntOffset(x.roundToPx(), 0) }
                .width(300.dp).fillMaxHeight().shadow(20.dp, shape).background(Theme.background, shape)
                .clickable(remember { MutableInteractionSource() }, null) { }
                .safeArea().padding(start = 20.dp, end = 16.dp, bottom = 8.dp),
            verticalArrangement = Arrangement.spacedBy(36.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                BasicText("Bumpy", Modifier.weight(1f), style = Theme.font(24, FontWeight.SemiBold, tracking = -0.6))
                CircleIconButton(Icon.CLOSE, "Close menu", "closeMenu", onClick = onClose)
            }
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                app.settings.dashboardUrl?.let { url ->
                    MenuItem(open, Icon.GLOBE, "Web app", "Your trips and the map", Icon.ARROW_UP_RIGHT, "menuWebApp", 140) {
                        context.openUrl(url)
                    }
                }
                MenuItem(open, Icon.SLIDERS, "Settings", "Server and device key", Icon.CHEVRON_RIGHT, "settingsButton", 210) {
                    onClose()
                    onSettings()
                }
            }
            Spacer(Modifier.weight(1f))
            BasicText("Version ${AppInfo.SHORT_VERSION}", Modifier.padding(horizontal = 4.dp), style = Theme.font(13, color = Theme.muted))
        }
    }
}

@Composable
private fun MenuItem(
    open: Boolean,
    icon: Icon,
    title: String,
    hint: String,
    trailing: Icon,
    id: String,
    delayMs: Int,
    onClick: () -> Unit,
) {
    var entered by remember { mutableStateOf(false) }
    LaunchedEffect(open) { entered = open }
    val shown by animateFloatAsState(if (entered) 1f else 0f, tween(400, if (entered) delayMs else 0), label = "item")
    Row(
        Modifier.fillMaxWidth().heightIn(min = 68.dp)
            .graphicsLayer {
                alpha = shown
                translationX = -16.dp.toPx() * (1 - shown)
            }
            .plainButton(id, onClick = onClick).padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(48.dp).background(Theme.surface, RoundedCornerShape(14.dp)), contentAlignment = Alignment.Center) {
            IconImage(icon, 20.dp, Theme.text, 1.6f)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            BasicText(title, style = Theme.font(17, FontWeight.SemiBold))
            BasicText(hint, style = Theme.font(14, color = Theme.muted))
        }
        IconImage(trailing, 12.dp, Theme.muted, 1.8f)
    }
}

fun android.content.Context.openUrl(url: String) {
    runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
}
