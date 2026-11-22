package com.chuds.sensorrecorder.ui

import android.content.Context
import android.text.format.DateFormat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.chuds.sensorrecorder.app.AppModel
import com.chuds.sensorrecorder.core.ISO8601
import com.chuds.sensorrecorder.core.SessionMetadata
import com.chuds.sensorrecorder.recording.TrackBuffer
import com.chuds.sensorrecorder.recording.TripFormat
import com.chuds.sensorrecorder.recording.TripSummary
import com.chuds.sensorrecorder.upload.TripCloudCopy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Date

/**
 * After the trip: is the data good, and how much of it reached the cloud. Everything computed in the cloud
 * (roughness, potholes, sickness) lives on the web dashboard only (D51).
 */
@Composable
fun RecapView(
    app: AppModel,
    metadata: SessionMetadata,
    trackPoints: List<TrackBuffer.Point>,
    openMenu: () -> Unit,
    onDone: () -> Unit,
) {
    val context = LocalContext.current
    val summary = remember(metadata) { TripSummary(metadata) }
    val subtitle = remember(metadata) { subtitle(context, metadata, summary, trackPoints) }
    var shownQuality by remember { mutableStateOf(0) }
    var cloud by remember { mutableStateOf<TripCloudCopy?>(null) }
    LaunchedEffect(metadata) {
        while (true) {
            // Directory listing and the ack record: never on the main thread.
            val state = withContext(Dispatchers.IO) { app.uploadQueue.tripState(metadata.sessionId) }
            cloud = TripCloudCopy(metadata.stats, state)
            delay(1000)
        }
    }
    LaunchedEffect(summary) {
        delay(350)
        shownQuality = summary.qualityPercent ?: 0
    }

    Column(
        Modifier.fillMaxSize().background(Theme.background).safeArea().padding(horizontal = Theme.gutter).padding(bottom = 8.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        CircleIconButton(Icon.MENU, "Menu", "menuButton", Modifier.offset(x = (-4).dp), onClick = openMenu)
        Spacer(Modifier.weight(1f))
        Column(Modifier.riseIn(0.1), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            BasicText("Trip saved", style = Theme.font(40, FontWeight.SemiBold, tracking = -1.2))
            BasicText(subtitle, style = Theme.font(17, color = Theme.muted))
        }
        if (summary.qualityPercent != null) {
            Column(
                Modifier.padding(top = 16.dp).riseIn(0.2).testTag("dataQuality").semantics(mergeDescendants = true) { },
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                NumericText(
                    "$shownQuality %",
                    Theme.font(72, FontWeight.SemiBold, if (summary.isPoor) Theme.problem else Theme.text, tracking = -3.0, mono = true),
                    durationMs = 1100,
                )
                BasicText("Data quality", style = Theme.font(17, FontWeight.SemiBold))
                summary.problem?.let { BasicText(it, style = Theme.font(15, color = Theme.problem)) }
            }
        }
        Spacer(Modifier.weight(1f))

        app.settings.dashboardUrl?.let { url ->
            Column(Modifier.riseIn(0.28)) {
                Hairline()
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 54.dp)
                        .plainButton("openTripOnWeb") { context.openUrl("$url/sessions/${metadata.sessionId}") },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BasicText("See the trip on the web", Modifier.weight(1f), style = Theme.font(17))
                    IconImage(Icon.ARROW_UP_RIGHT, 14.dp, Theme.text, 1.6f)
                }
                Hairline()
            }
        }

        Column(Modifier.riseIn(0.34), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            UploadBlock(app, cloud)
            PrimaryButton("Done", "recapDone", Modifier.padding(top = 6.dp), onClick = onDone)
        }
    }
}

@Composable
fun Hairline() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
}

@Composable
private fun UploadBlock(app: AppModel, cloud: TripCloudCopy?) {
    if (!app.settings.uploadConfig.isEnabled) {
        BasicText(
            "Upload off · the trip is kept on this phone", Modifier.testTag("uploadProgress"), style = Theme.font(13, color = Theme.muted),
        )
        return
    }
    val percent = cloud?.percent ?: 0
    val bar by animateFloatAsState(percent / 100f, tween(800), label = "cloud")
    Column(
        Modifier.testTag("uploadProgress").semantics(mergeDescendants = true) { },
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(Modifier.fillMaxWidth()) {
            BasicText("Trip in the cloud", Modifier.weight(1f).alignByBaseline(), style = Theme.font(15, color = Theme.muted))
            NumericText("$percent %", Theme.font(28, FontWeight.SemiBold, mono = true), Modifier.alignByBaseline(), durationMs = 400)
        }
        Box(Modifier.fillMaxWidth().height(4.dp).background(Theme.line, CircleShape)) {
            Box(Modifier.fillMaxHeight().fillMaxWidth(bar).background(Theme.ink, CircleShape))
        }
        val warning = cloud?.let(::uploadWarning)
        BasicText(
            // Upload problems are WARN at most: the data is safe on disk.
            warning ?: if (cloud?.isComplete == true) "Complete. The web shows the whole trip."
            else "The rest is saved on this phone and uploads when you have signal.",
            style = Theme.font(13, color = if (warning != null) Theme.warn else Theme.muted),
        )
    }
}

/** Parts the live upload will not deliver by itself: say what the operator has to do. */
private fun uploadWarning(cloud: TripCloudCopy): String? {
    val parts = listOfNotNull(
        if (cloud.partsNeverQueued > 0) "${cloud.partsNeverQueued} part(s) of this trip never went into the live upload." else null,
        if (cloud.rejectedParts > 0) "${cloud.rejectedParts} part(s) were rejected by the server; retry them in Settings." else null,
    )
    if (parts.isEmpty()) return null
    return (parts + "Everything is kept on this phone: upload the trip from a laptop so the web has all of it.").joinToString(" ")
}

/** "Today, 14:05 · 42 min · 18.6 km". */
private fun subtitle(context: Context, metadata: SessionMetadata, summary: TripSummary, points: List<TrackBuffer.Point>): String {
    val parts = ArrayList<String>()
    ISO8601.utcMs(metadata.startedAtUtc)?.let { ms ->
        val date = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).toLocalDate()
        val day = when (date) {
            LocalDate.now() -> "Today"
            LocalDate.now().minusDays(1) -> "Yesterday"
            else -> date.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))
        }
        parts.add("$day, ${DateFormat.getTimeFormat(context).format(Date(ms))}")
    }
    parts.add(TripFormat.duration(summary.durationSec))
    val meters = TripSummary.distanceMeters(points)
    if (meters > 0) parts.add(TripFormat.distance(meters))
    return parts.joinToString(" · ")
}
