package com.genericjam.operator

import android.content.Context
import android.graphics.Typeface
import android.text.Spannable
import android.text.TextPaint
import android.text.method.ArrowKeyMovementMethod
import android.text.style.ClickableSpan
import android.text.style.ForegroundColorSpan
import android.text.style.MetricAffectingSpan
import android.text.style.RelativeSizeSpan
import android.text.util.Linkify
import android.util.TypedValue
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.widget.TextView
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.res.ResourcesCompat
import io.noties.markwon.AbstractMarkwonPlugin
import io.noties.markwon.Markwon
import io.noties.markwon.MarkwonConfiguration
import io.noties.markwon.MarkwonSpansFactory
import io.noties.markwon.core.CoreProps
import io.noties.markwon.core.MarkwonTheme
import io.noties.markwon.ext.strikethrough.StrikethroughPlugin
import io.noties.markwon.ext.tables.TablePlugin
import io.noties.markwon.html.HtmlPlugin
import io.noties.markwon.linkify.LinkifyPlugin
import org.commonmark.node.Emphasis
import org.commonmark.node.Heading
import org.commonmark.node.StrongEmphasis

// The native Markdown view behind Operator.Core.MarkdownView (see its
// moduledoc for the props contract): Markwon renders an assistant reply's
// Markdown to Spannables in a selectable TextView, so inline styles wrap like
// prose and any text can be drag-selected and copied.
//
// One Markwon instance (and one set of faces) serves every row; it is rebuilt
// only when the theme props change. A row's TextView is created once and only
// re-rendered when its `text` prop changes (a streaming reply grows every
// ~100 ms; finished rows never change).
//
// Bold / italic use the theme's real JetBrains Mono faces (no synthesized
// weight or skew); code keeps the regular mono face at full size.

object OperatorMarkdown {
    /** The registry name of Operator.Core.MarkdownView. */
    const val NAME = "Operator_Core_MarkdownView"

    fun register() {
        MobNativeViewRegistry.register(NAME) { props, send -> OperatorMarkdownView(props, send) }
    }

    private var facesKey: List<String>? = null
    private var faces: MdFaces? = null
    private var markwonStyle: MdStyle? = null
    private var markwon: Markwon? = null

    // Main thread only (Compose).
    internal fun markwon(context: Context, style: MdStyle): Markwon {
        markwon?.let { if (style == markwonStyle) return it }
        val built = build(context.applicationContext, style, faces(context, style))
        markwon = built
        markwonStyle = style
        return built
    }

    internal fun faces(context: Context, style: MdStyle): MdFaces {
        val key = listOf(style.fontRegular, style.fontBold, style.fontItalic, style.fontBoldItalic)
        faces?.let { if (key == facesKey) return it }
        val ctx = context.applicationContext
        val loaded = MdFaces(
            regular = font(ctx, style.fontRegular, Typeface.NORMAL),
            bold = font(ctx, style.fontBold, Typeface.BOLD),
            italic = font(ctx, style.fontItalic, Typeface.ITALIC),
            boldItalic = font(ctx, style.fontBoldItalic, Typeface.BOLD_ITALIC),
        )
        faces = loaded
        facesKey = key
        return loaded
    }

    // A bundled res/font face by name (normalised like MobBridge's font
    // lookup), else the system monospace in that style.
    private fun font(ctx: Context, name: String, fallbackStyle: Int): Typeface {
        val res = name.lowercase().replace(Regex("[^a-z0-9_]"), "_")
        val id = if (res.isEmpty()) 0 else ctx.resources.getIdentifier(res, "font", ctx.packageName)
        if (id != 0) {
            try {
                ResourcesCompat.getFont(ctx, id)?.let { return it }
            } catch (e: Exception) {
                android.util.Log.w("OperatorMarkdown", "font $res failed to load: ${e.message}")
            }
        }
        return Typeface.create(Typeface.MONOSPACE, fallbackStyle)
    }

    private fun build(ctx: Context, style: MdStyle, faces: MdFaces): Markwon {
        val px = { sp: Float ->
            TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, ctx.resources.displayMetrics)
        }
        val textPx = px(style.textSize).toInt()
        val pad = px(style.textSize / 2).toInt()

        return Markwon.builder(ctx)
            .usePlugin(StrikethroughPlugin.create())
            .usePlugin(TablePlugin.create(TablePlugin.ThemeConfigure { b ->
                b.tableBorderColor(style.ruleColor)
                    .tableBorderWidth(1)
                    .tableCellPadding(pad)
                    .tableHeaderRowBackgroundColor(style.codeBackground)
                    .tableEvenRowBackgroundColor(0)
                    .tableOddRowBackgroundColor(0)
            }))
            .usePlugin(LinkifyPlugin.create(Linkify.WEB_URLS or Linkify.EMAIL_ADDRESSES))
            .usePlugin(HtmlPlugin.create())
            .usePlugin(object : AbstractMarkwonPlugin() {
                override fun configureTheme(builder: MarkwonTheme.Builder) {
                    builder
                        .codeTextColor(style.codeColor)
                        .codeBackgroundColor(style.codeBackground)
                        .codeTypeface(faces.regular)
                        .codeTextSize(textPx)
                        .codeBlockTextColor(style.codeColor)
                        .codeBlockBackgroundColor(style.codeBackground)
                        .codeBlockTypeface(faces.regular)
                        .codeBlockTextSize(textPx)
                        .linkColor(style.linkColor)
                        .isLinkUnderlined(true)
                        .blockQuoteColor(style.quoteColor)
                        .listItemColor(style.quoteColor)
                        .thematicBreakColor(style.ruleColor)
                        .headingBreakHeight(0)
                }

                // Links go to the BEAM (Operator.Core.MarkdownView handles
                // "open_link"), through the row's current `send`.
                override fun configureConfiguration(builder: MarkwonConfiguration.Builder) {
                    builder.linkResolver { view, link ->
                        (view.tag as? MdHolder)?.send?.invoke("open_link", mapOf("url" to link))
                    }
                }

                override fun configureSpansFactory(builder: MarkwonSpansFactory.Builder) {
                    builder.setFactory(StrongEmphasis::class.java) { _, _ -> FaceSpan(faces, bold = true) }
                    builder.setFactory(Emphasis::class.java) { _, _ -> FaceSpan(faces, bold = false) }
                    builder.setFactory(Heading::class.java) { _, props ->
                        val level = CoreProps.HEADING_LEVEL.require(props)
                        arrayOf(
                            RelativeSizeSpan(HEADING_SIZES[(level - 1).coerceIn(0, HEADING_SIZES.size - 1)]),
                            FaceSpan(faces, bold = true),
                            ForegroundColorSpan(style.headingColor),
                        )
                    }
                }
            })
            .build()
    }

    // Terminal-like: headings stand out by face and colour more than size.
    private val HEADING_SIZES = floatArrayOf(1.25f, 1.15f, 1.05f, 1f, 1f, 1f)
}

internal data class MdStyle(
    val textSize: Float,
    val lineHeight: Float,
    val textColor: Int,
    val headingColor: Int,
    val linkColor: Int,
    val codeColor: Int,
    val codeBackground: Int,
    val quoteColor: Int,
    val ruleColor: Int,
    val selectionColor: Int,
    val fontRegular: String,
    val fontBold: String,
    val fontItalic: String,
    val fontBoldItalic: String,
) {
    companion object {
        fun from(props: Map<String, Any?>): MdStyle {
            fun color(key: String, default: Long) = ((props[key] as? Number)?.toLong() ?: default).toInt()
            fun float(key: String, default: Float) = (props[key] as? Number)?.toFloat() ?: default
            fun font(key: String) = props[key] as? String ?: ""
            return MdStyle(
                textSize = float("text_size", 13f),
                lineHeight = float("line_height", 1.25f),
                textColor = color("text_color", 0xFFD6DEEB),
                headingColor = color("heading_color", 0xFF82AAFF),
                linkColor = color("link_color", 0xFF7FDBCA),
                codeColor = color("code_color", 0xFFC3E88D),
                codeBackground = color("code_background", 0xFF141922),
                quoteColor = color("quote_color", 0xFF6B7489),
                ruleColor = color("rule_color", 0xFF6B7489),
                selectionColor = color("selection_color", 0xFFC792EA),
                fontRegular = font("font_regular"),
                fontBold = font("font_bold"),
                fontItalic = font("font_italic"),
                fontBoldItalic = font("font_bold_italic"),
            )
        }
    }
}

internal class MdFaces(val regular: Typeface, val bold: Typeface, val italic: Typeface, val boldItalic: Typeface) {
    /** `current` plus bold (`addBold`) or plus italic, as one real face. */
    fun plus(current: Typeface?, addBold: Boolean): Typeface {
        val b = addBold || current === bold || current === boldItalic
        val i = !addBold || current === italic || current === boldItalic
        return when {
            b && i -> boldItalic
            b -> bold
            i -> italic
            else -> regular
        }
    }
}

// Strong / emphasis as a real face. Nested styles compose whatever order the
// spans apply in: each adds its trait to the face already on the paint.
private class FaceSpan(private val faces: MdFaces, private val bold: Boolean) : MetricAffectingSpan() {
    override fun updateDrawState(tp: TextPaint) = restyle(tp)
    override fun updateMeasureState(tp: TextPaint) = restyle(tp)

    private fun restyle(tp: TextPaint) {
        tp.typeface = faces.plus(tp.typeface, bold)
    }
}

// A row's view state: what it last rendered, and the `send` of its latest
// composition (MobNativeViewRegistry makes a new one per render).
private class MdHolder {
    var text: String? = null
    var style: MdStyle? = null
    var send: MobNativeSend? = null
}

// Selection stays the TextView's own (long-press, handles, Copy); a short tap
// on a link (with no selection showing) follows it. LinkMovementMethod would
// also follow a link after a long-press and drop the selection on any tap.
private object SelectableLinkMovement : ArrowKeyMovementMethod() {
    override fun onTouchEvent(widget: TextView, buffer: Spannable, event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_UP &&
            event.eventTime - event.downTime < ViewConfiguration.getLongPressTimeout() &&
            !widget.hasSelection()
        ) {
            val layout = widget.layout
            if (layout != null) {
                val x = event.x.toInt() - widget.totalPaddingLeft + widget.scrollX
                val y = event.y.toInt() - widget.totalPaddingTop + widget.scrollY
                val line = layout.getLineForVertical(y)
                if (x >= layout.getLineLeft(line) && x <= layout.getLineRight(line)) {
                    val offset = layout.getOffsetForHorizontal(line, x.toFloat())
                    val links = buffer.getSpans(offset, offset, ClickableSpan::class.java)
                    if (links.isNotEmpty()) {
                        links[0].onClick(widget)
                        return true
                    }
                }
            }
        }
        return super.onTouchEvent(widget, buffer, event)
    }
}

@Composable
fun OperatorMarkdownView(props: Map<String, Any?>, send: MobNativeSend) {
    val style = MdStyle.from(props)
    val text = props["text"] as? String ?: ""

    AndroidView(
        modifier = Modifier.fillMaxWidth(),
        factory = { ctx ->
            TextView(ctx).apply {
                tag = MdHolder()
                background = null
                setPadding(0, 0, 0, 0)
                setTextIsSelectable(true)
                movementMethod = SelectableLinkMovement
            }
        },
        update = { tv ->
            val holder = tv.tag as MdHolder
            holder.send = send
            if (holder.style != style) {
                tv.typeface = OperatorMarkdown.faces(tv.context, style).regular
                tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, style.textSize)
                tv.setLineSpacing(0f, style.lineHeight)
                tv.setTextColor(style.textColor)
                tv.setLinkTextColor(style.linkColor)
                tv.highlightColor = (style.selectionColor and 0x00FFFFFF) or 0x66000000
                holder.style = style
                holder.text = null
            }
            if (holder.text != text) {
                OperatorMarkdown.markwon(tv.context, style).setMarkdown(tv, text)
                holder.text = text
            }
        },
    )
}
