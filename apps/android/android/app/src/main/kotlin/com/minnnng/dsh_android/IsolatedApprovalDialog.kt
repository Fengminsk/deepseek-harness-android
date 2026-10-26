package com.minnnng.dsh_android

import android.app.Activity
import android.app.AlertDialog
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.Button
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject

/** A native, foreground-only confirmation for one immutable App-prepared scope. */
internal object IsolatedApprovalDialog {
    private fun Activity.dp(value: Int): Int =
        (resources.displayMetrics.density * value + 0.5f).toInt()

    private fun surface(fill: Int, edge: Int, radius: Float) = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = radius
        setColor(fill)
        setStroke(1, edge)
    }

    private fun gradient(top: Int, bottom: Int, edge: Int, radius: Float) =
        GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(top, bottom)).apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = radius
            setStroke(1, edge)
        }

    fun create(activity: Activity, review: JSONObject, onAllow: () -> Unit,
               onDismiss: () -> Unit): AlertDialog {
        val dark = activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES
        val titleColor = if (dark) Color.WHITE else 0xFF17191B.toInt()
        val secondary = if (dark) 0xFFBABCC0.toInt() else 0xFF555B60.toInt()
        val card = if (dark) 0xEE2B2C30.toInt() else 0xF5F8F9FA.toInt()
        val edge = if (dark) 0x66FFFFFF else 0x665F676D

        fun label(text: String, size: Float, bold: Boolean, color: Int) = TextView(activity).apply {
            this.text = text
            setTextColor(color)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
            if (bold) setTypeface(typeface, Typeface.BOLD)
            includeFontPadding = false
            setLineSpacing(activity.dp(3).toFloat(), 1f)
        }

        fun paths(key: String): List<String> {
            val values = review.getJSONArray(key)
            return (0 until values.length()).map { values.getString(it) }
        }

        val root = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(activity.dp(22), activity.dp(20), activity.dp(22), activity.dp(20))
            background = surface(card, edge, activity.dp(28).toFloat())
        }
        root.addView(label("允许隔离脚本访问？", 19f, true, titleColor))
        root.addView(label("仅限运行 ${review.getString("runId").take(8)} · ${review.getLong("leaseMillis") / 1000} 秒",
            13f, false, secondary), LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = activity.dp(8) })

        val details = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, activity.dp(8), activity.dp(4), activity.dp(8))
        }
        fun section(name: String, values: List<String>) {
            val heading = label(name, 13f, true, secondary)
            details.addView(heading, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = activity.dp(15) })
            details.addView(label(if (values.isEmpty()) "无" else values.joinToString("\n") { "• $it" },
                15f, false, titleColor), LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = activity.dp(5) })
        }
        val workspace = review.optString("workspacePath")
            .takeUnless { it.isBlank() || it == "null" }
        section("工作区", listOfNotNull(workspace))
        section("可读取", paths("readablePaths"))
        section("可写入", paths("writablePaths"))
        section("允许联网的域名", paths("exactHosts"))
        section("调用额度", listOf(
            "文件 ${review.getInt("fileCallLimit")} 次 · 网络 ${review.getInt("networkCallLimit")} 次",
        ))
        section("程序 SHA-256", listOf(review.getString("programSha256")))
        val codeHeading = label("执行代码（只读）", 13f, true, secondary)
        details.addView(codeHeading, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = activity.dp(15) })
        details.addView(label(review.getString("program"), 13f, false, titleColor).apply {
            typeface = Typeface.MONOSPACE
            setTextIsSelectable(false)
        }, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = activity.dp(5) })

        val scroll = ScrollView(activity).apply {
            isFillViewport = false
            isVerticalScrollBarEnabled = true
            addView(details)
        }
        root.addView(scroll, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            minOf(activity.dp(400), (activity.resources.displayMetrics.heightPixels * 0.48f).toInt()),
        ).apply { topMargin = activity.dp(8) })

        root.addView(label("仅授权上述隔离脚本；Shell 命令仍需逐条确认。", 12f,
            false, secondary), LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = activity.dp(10) })

        val actions = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        fun button(text: String, highlighted: Boolean, clicked: () -> Unit): Button =
            Button(activity).apply {
                this.text = text
                setTextColor(if (highlighted) 0xFF1A2817.toInt() else titleColor)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                setTypeface(typeface, Typeface.BOLD)
                isAllCaps = false
                includeFontPadding = false
                gravity = Gravity.CENTER
                minHeight = activity.dp(50)
                background = if (highlighted)
                    gradient(0xFFD3EDC5.toInt(), 0xFFA3CF92.toInt(), 0xDDFFFFFF.toInt(),
                        activity.dp(25).toFloat())
                else gradient(
                    if (dark) 0xFF4B4C50.toInt() else 0xFFE8EAEC.toInt(),
                    if (dark) 0xFF38393D.toInt() else 0xFFD5D9DC.toInt(),
                    edge, activity.dp(25).toFloat(),
                )
                stateListAnimator = null
                isClickable = true
                isFocusable = true
                setOnClickListener { clicked() }
            }

        lateinit var dialog: AlertDialog
        actions.addView(button("返回", false) { dialog.dismiss() }, LinearLayout.LayoutParams(
            0, activity.dp(50), 1f,
        ).apply { marginEnd = activity.dp(10) })
        actions.addView(button("仅此任务允许", true) {
            onAllow()
            dialog.dismiss()
        }, LinearLayout.LayoutParams(0, activity.dp(50), 1f))
        root.addView(actions, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = activity.dp(18) })

        dialog = AlertDialog.Builder(activity).setView(root).create()
        dialog.setOnDismissListener { onDismiss() }
        dialog.setOnShowListener {
            dialog.window?.apply {
                setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
                setLayout(
                    minOf(activity.resources.displayMetrics.widthPixels - activity.dp(32), activity.dp(460)),
                    WindowManager.LayoutParams.WRAP_CONTENT,
                )
                addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
                setDimAmount(0.56f)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    addFlags(WindowManager.LayoutParams.FLAG_BLUR_BEHIND)
                    attributes = attributes.apply { blurBehindRadius = activity.dp(22) }
                }
            }
        }
        return dialog
    }
}
