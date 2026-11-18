package com.example.nondesign

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

/**
 * `.nonapp` 文件的系统打开入口（Android）。
 *
 * 契约与 macOS/iOS 同一套 `nc/open` 通道：
 *   native → Dart `openPath` {path}   运行中直接投递
 *   Dart → native `takePending` → List<String>  冷启动/积压队列
 *
 * 冷启动时 Dart 尚未注册 handler，直投会静默丢——所以**一切先入队**
 * （SharedPreferences），Dart 就绪后自己来拉；运行中则入队后立刻投递
 * （Dart 侧 2s 去重吃掉重复）。
 *
 * content://（`ACTION_VIEW`/`ACTION_SEND` 常见的分享 URI）先由
 * contentResolver 拷到 `cacheDir/nonapp_inbox/` 再入队——Dart 侧只读本地
 * 文件（URI 授权在进程重启后失效）。
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nc/open")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePending" -> result.success(takePending())
                else -> result.notImplemented()
            }
        }
        channel = ch
        // 冷启动 intent 已在 onCreate 入队；Dart 侧 attach 时会拉，无需这里推。
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        queueFromIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        queueFromIntent(intent)
        // 运行中：入队后立即直投（Dart 已就绪；未就绪时队列兜底）。
        deliverPending()
    }

    private fun queueFromIntent(intent: Intent?) {
        if (intent == null) return
        // 声明为非空 Uri（`: Uri` 而非 `Uri?`）：K2 不再按 `?: return` 的
        // 初始化式收窄显式可空声明的局部 val，保留 `Uri?` 会让
        // materialize(uri) 报 "actual type is 'Uri?', but 'Uri' was expected"。
        val uri: Uri = when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> streamOf(intent)
            else -> null
        } ?: return
        val path = materialize(uri) ?: return
        enqueue(path)
    }

    private fun streamOf(intent: Intent): Uri? {
        @Suppress("DEPRECATION")
        return intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
    }

    /** file:// 直接用路径；content:// 拷到应用缓存（进程重启后仍可读）。 */
    private fun materialize(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path
        return try {
            val dir = File(cacheDir, "nonapp_inbox").apply { mkdirs() }
            val dest = File(dir, "${System.currentTimeMillis()}-${UUID.randomUUID()}.nonapp")
            contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { out -> input.copyTo(out) }
            } ?: return null
            dest.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    private fun prefs() = getSharedPreferences("nonapp_open", MODE_PRIVATE)

    private fun enqueue(path: String) {
        val all = prefs().getStringSet("pending", emptySet())!!.toMutableSet()
        all.add(path)
        prefs().edit().putStringSet("pending", all).apply()
    }

    private fun takePending(): List<String> {
        val all = prefs().getStringSet("pending", emptySet())!!.toList()
        prefs().edit().remove("pending").apply()
        return all
    }

    private fun deliverPending() {
        val ch = channel ?: return
        for (path in takePending()) {
            ch.invokeMethod("openPath", mapOf("path" to path))
        }
    }
}
