package com.chuds.sensorrecorder.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import com.chuds.sensorrecorder.R
import com.chuds.sensorrecorder.core.HealthLevel
import kotlinx.coroutines.delay
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin

/**
 * The iOS app's neutral palette (light only), ink-black accent. Colour appears only when something is
 * wrong: amber WARN, red PROBLEM; OK is plain text.
 */
object Theme {
    val background = Color.White
    val surface = Color(0xFFF5F5F5)
    val text = Color(0xFF0A0A0A)
    val muted = Color(0xFF737373)
    val line = Color(0xFFE5E5E5)
    val placeholder = Color(0xFFC4C4C6)

    /** Primary buttons, the recording dot, progress bars. */
    val ink = Color(0xFF0A0A0A)
    val onInk = Color.White
    val warn = Color(0xFFB45309)
    val problem = Color(0xFFB91C1C)
    val scrim = Color(0xFF0A0A0A).copy(alpha = 0.35f)
    val gutter = 16.dp

    fun color(level: HealthLevel) = when (level) {
        HealthLevel.OK -> muted
        HealthLevel.WARN -> warn
        HealthLevel.PROBLEM -> problem
    }

    /** Geist, the web dashboard's typeface (variable font, SIL OFL). */
    @OptIn(ExperimentalTextApi::class)
    private val geist = FontFamily(
        listOf(FontWeight.Normal, FontWeight.Medium, FontWeight.SemiBold, FontWeight.Bold).map {
            Font(R.font.geist_variable, it, variationSettings = FontVariation.Settings(FontVariation.weight(it.weight)))
        },
    )

    /**
     * Fixed sizes like the design ([size] and [tracking] in dp, which are iOS points): the layout is built
     * for one glance in a moving car, not for the system font scale.
     */
    @Composable
    fun font(
        size: Int,
        weight: FontWeight = FontWeight.Normal,
        color: Color = text,
        tracking: Double = 0.0,
        mono: Boolean = false,
        lineHeight: Int? = null,
    ): TextStyle {
        val density = LocalDensity.current
        return TextStyle(
            color = color,
            fontSize = with(density) { size.dp.toSp() },
            fontFamily = geist,
            fontWeight = weight,
            letterSpacing = (tracking / size).em,
            fontFeatureSettings = if (mono) "tnum" else null,
            lineHeight = lineHeight?.let { with(density) { it.dp.toSp() } } ?: TextUnit.Unspecified,
        )
    }

    /** SwiftUI's `.spring(response:dampingFraction:)`. */
    fun <T> spring(response: Double, damping: Float): SpringSpec<T> =
        androidx.compose.animation.core.spring(damping, (2 * PI / response).pow(2).toFloat())
}

/** A multi-line headline with tight leading (design: line-height 1.05). */
@Composable
fun Headline(lines: List<String>, modifier: Modifier = Modifier) {
    Column(
        modifier.clearAndSetSemantics {
            contentDescription = lines.joinToString(" ")
            heading()
        },
    ) {
        for (l in lines) {
            Box(Modifier.height(42.dp), contentAlignment = Alignment.CenterStart) {
                BasicText(
                    l, Modifier.wrapContentHeight(unbounded = true), // taller than its line: descenders must not be cut
                    style = Theme.font(40, FontWeight.SemiBold, tracking = -1.2),
                )
            }
        }
    }
}

/** A tap target without ripple that dims while pressed (SwiftUI's `.plain` button). */
fun Modifier.plainButton(id: String, label: String? = null, enabled: Boolean = true, onClick: () -> Unit): Modifier = composed {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    alpha(if (pressed) 0.5f else 1f)
        .clickable(source, indication = null, enabled = enabled, onClickLabel = label, role = Role.Button, onClick = onClick)
        .then(if (label != null) Modifier.semantics { contentDescription = label } else Modifier)
        .testTag(id)
}

/** The black 56 dp button used for the one main action on each screen. */
@Composable
fun PrimaryButton(text: String, id: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.98f else 1f, tween(150), label = "press")
    Box(
        modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .background(Theme.ink, RoundedCornerShape(14.dp))
            .clickable(source, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
            .testTag(id),
        contentAlignment = Alignment.Center,
    ) {
        BasicText(text, style = Theme.font(17, FontWeight.SemiBold, Theme.onInk))
    }
}

/** 44 dp round outline button (menu, close, back); the hit target stays 44 dp for a smaller circle. */
@Composable
fun CircleIconButton(icon: Icon, label: String, id: String, modifier: Modifier = Modifier, size: Dp = 44.dp, onClick: () -> Unit) {
    Box(modifier.size(44.dp).plainButton(id, label, onClick = onClick), contentAlignment = Alignment.Center) {
        Box(Modifier.size(size).border(1.dp, Theme.line, CircleShape), contentAlignment = Alignment.Center) {
            IconImage(icon, if (size > 40.dp) 17.dp else 14.dp, Theme.text, 2f)
        }
    }
}

/** A dot that keeps rippling while recording: proof at a glance that the app is alive. */
@Composable
fun PulsingDot() {
    val t = rememberInfiniteTransition(label = "pulse")
    val p by t.animateFloat(0f, 1f, infiniteRepeatable(tween(1600, easing = LinearOutSlowInEasing), RepeatMode.Restart), label = "pulse")
    Canvas(Modifier.size(10.dp)) {
        drawCircle(Theme.ink.copy(alpha = 0.4f * (1 - p)), radius = size.width / 2 * (1 + 1.8f * p))
        drawCircle(Theme.ink.copy(alpha = 1 - 0.45f * p), radius = size.width / 2)
    }
}

@Composable
fun Dot(color: Color, size: Dp) {
    Box(Modifier.size(size).background(color, CircleShape))
}

/** Lines that rise in one after another when a screen appears. */
fun Modifier.riseIn(delaySeconds: Double): Modifier = composed {
    val shown = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        delay((delaySeconds * 1000).toLong())
        shown.animateTo(1f, Theme.spring(0.6, 0.85f))
    }
    graphicsLayer {
        alpha = shown.value.coerceIn(0f, 1f)
        translationY = (1 - shown.value) * 20.dp.toPx()
    }
}

/** A number whose digits roll when they change (SwiftUI's `.contentTransition(.numericText())`). */
@Composable
fun NumericText(text: String, style: TextStyle, modifier: Modifier = Modifier, durationMs: Int = 600) {
    Row(modifier.clearAndSetSemantics { contentDescription = text }) {
        text.forEachIndexed { i, c ->
            // Keyed from the right, so "0 %" → "97 %" rolls the ones digit into place.
            key(text.length - i) {
                AnimatedContent(
                    c,
                    transitionSpec = {
                        (slideInVertically(tween(durationMs)) { it / 2 } + fadeIn(tween(durationMs)))
                            .togetherWith(slideOutVertically(tween(durationMs)) { -it / 2 } + fadeOut(tween(durationMs / 2)))
                    },
                    label = "digit",
                ) { BasicText(it.toString(), style = style) }
            }
        }
    }
}

/** Stand-ins for the SF Symbols the iOS app uses, on a 24 × 24 grid. */
enum class Icon { MENU, CLOSE, GLOBE, SLIDERS, ARROW_UP_RIGHT, CHEVRON_RIGHT, CHEVRON_LEFT, ARROW_CLOCKWISE }

@Composable
fun IconImage(icon: Icon, size: Dp, color: Color, strokeDp: Float, modifier: Modifier = Modifier) {
    Canvas(modifier.size(size)) { draw(icon, color, strokeDp.dp.toPx()) }
}

private fun DrawScope.draw(icon: Icon, color: Color, w: Float) {
    val u = size.width / 24
    val stroke = Stroke(w, cap = StrokeCap.Round, join = StrokeJoin.Round)
    fun line(x1: Float, y1: Float, x2: Float, y2: Float) =
        drawLine(color, Offset(x1 * u, y1 * u), Offset(x2 * u, y2 * u), w, StrokeCap.Round)
    fun poly(vararg p: Float) = drawPath(
        Path().apply {
            moveTo(p[0] * u, p[1] * u)
            for (i in 2 until p.size step 2) lineTo(p[i] * u, p[i + 1] * u)
        },
        color, style = stroke,
    )
    when (icon) {
        Icon.MENU -> for (y in listOf(5f, 12f, 19f)) line(1.5f, y, 22.5f, y)
        Icon.CLOSE -> {
            line(3.5f, 3.5f, 20.5f, 20.5f)
            line(20.5f, 3.5f, 3.5f, 20.5f)
        }
        Icon.CHEVRON_RIGHT -> poly(8f, 3f, 17f, 12f, 8f, 21f)
        Icon.CHEVRON_LEFT -> poly(16f, 3f, 7f, 12f, 16f, 21f)
        Icon.ARROW_UP_RIGHT -> {
            line(4.5f, 19.5f, 19f, 5f)
            poly(8f, 4.5f, 19.5f, 4.5f, 19.5f, 16f)
        }
        Icon.GLOBE -> {
            drawCircle(color, 10.5f * u, style = stroke)
            drawOval(color, Offset(7.2f * u, 1.5f * u), Size(9.6f * u, 21f * u), style = stroke)
            line(1.5f, 12f, 22.5f, 12f)
            line(12f, 1.5f, 12f, 22.5f)
        }
        Icon.SLIDERS -> for ((y, knob) in listOf(5f to 16f, 12f to 8f, 19f to 16f)) {
            line(1.5f, y, knob - 3.2f, y)
            line(knob + 3.2f, y, 22.5f, y)
            drawCircle(color, 2.6f * u, Offset(knob * u, y * u), style = stroke)
        }
        Icon.ARROW_CLOCKWISE -> {
            val r = 9.5f
            drawArc(color, -35f, 310f, false, Offset((12 - r) * u, (12 - r) * u), Size(2 * r * u, 2 * r * u), style = stroke)
            val a = Math.toRadians(-35.0)
            val x = 12 + r * cos(a).toFloat()
            val y = 12 + r * sin(a).toFloat()
            poly(x - 0.2f, y - 6f, x, y, x - 6f, y - 0.2f)
        }
    }
}
