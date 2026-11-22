package com.chuds.sensorrecorder.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.chuds.sensorrecorder.core.HealthLevel
import com.chuds.sensorrecorder.recording.RecordingController
import com.chuds.sensorrecorder.recording.TripFormat
import kotlinx.coroutines.delay

/**
 * While recording: a ticking timer (proof it's alive), one status line, and the only control, a 2 s hold
 * to end the trip (spec §8: no single-tap stop, no pause).
 */
@Composable
fun RecordingView(controller: RecordingController, openMenu: () -> Unit, onStop: () -> Unit) {
    val (text, level) = controller.statusLine
    val color by animateColorAsState(Theme.color(level), tween(300), label = "status")
    Column(
        Modifier.fillMaxSize().background(Theme.background).safeArea().padding(horizontal = Theme.gutter).padding(bottom = 8.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp), horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        CircleIconButton(Icon.MENU, "Menu", "menuButton", Modifier.align(Alignment.Start).offset(x = (-4).dp), onClick = openMenu)
        Spacer(Modifier.weight(1f))
        Timer(TripFormat.timer(controller.elapsed), Modifier.riseIn(0.12))
        Row(Modifier.riseIn(0.22), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            PulsingDot()
            BasicText("Recording", style = Theme.font(17, FontWeight.SemiBold))
        }
        Spacer(Modifier.weight(1f))
        Row(
            Modifier.riseIn(0.3).testTag("statusLine").semantics(mergeDescendants = true) { stateDescription = level.label },
            horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            if (level != HealthLevel.OK) Dot(color, 6.dp)
            BasicText(text, style = Theme.font(15, color = color).copy(textAlign = TextAlign.Center))
        }
        HoldToEndButton(onStop)
    }
}

/** 96 dp digits, scaled down (to 60 % at most) when `1:02:17` doesn't fit. */
@Composable
private fun Timer(text: String, modifier: Modifier) {
    val style = Theme.font(96, FontWeight.SemiBold, tracking = -4.0, mono = true)
    val measurer = rememberTextMeasurer()
    BoxWithConstraints(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        val widest = remember(text.length, style) { measurer.measure(text.replace(Regex("\\d"), "0"), style, maxLines = 1, softWrap = false).size.width }
        val scale = (constraints.maxWidth.toFloat() / widest).coerceIn(0.6f, 1f)
        BasicText(text, Modifier.testTag("elapsed"), style = style.copy(fontSize = style.fontSize * scale), maxLines = 1, softWrap = false)
    }
}

/** Stop needs a 2 s long-press (spec §8): no accidental stop, no pause. */
@Composable
private fun HoldToEndButton(action: () -> Unit) {
    var pressing by remember { mutableStateOf(false) }
    val progress = remember { Animatable(0f) }
    val scale by animateFloatAsState(if (pressing) 0.98f else 1f, tween(200), label = "press")
    val onHeld by rememberUpdatedState(action)
    LaunchedEffect(pressing) {
        if (!pressing) {
            progress.animateTo(0f, tween(200))
        } else {
            progress.animateTo(1f, tween(HOLD_MS, easing = LinearEasing))
        }
    }
    // Its own timer: the animation would end at once with the system's animations switched off.
    LaunchedEffect(pressing) {
        if (pressing) {
            delay(HOLD_MS.toLong())
            pressing = false
            onHeld()
        }
    }
    Box(
        Modifier.fillMaxWidth().height(56.dp)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .clip(RoundedCornerShape(14.dp)).background(Theme.ink)
            .pointerInput(Unit) {
                val limit = 40.dp.toPx()
                awaitEachGesture {
                    val down = awaitFirstDown()
                    pressing = true
                    while (true) {
                        val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id }
                        if (change == null || !change.pressed || (change.position - down.position).getDistance() > limit) break
                    }
                    pressing = false
                }
            }
            .testTag("holdToStop")
            .clearAndSetSemantics {
                contentDescription = "Hold for two seconds to end the trip"
                role = Role.Button
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.align(Alignment.CenterStart).fillMaxHeight().fillMaxWidth(progress.value).background(Color.White.copy(alpha = 0.22f), RoundedCornerShape(14.dp)))
        BasicText(if (pressing) "Keep holding…" else "Hold to end trip", style = Theme.font(17, FontWeight.SemiBold, Theme.onInk))
    }
}

private const val HOLD_MS = 2000
