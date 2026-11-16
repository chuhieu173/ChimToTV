package vn.chimto.tv

import android.os.Build
import android.util.Log
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoRuntime
import org.mozilla.geckoview.GeckoRuntimeSettings
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoSessionSettings
import org.mozilla.geckoview.GeckoWebExecutor
import org.mozilla.geckoview.WebRequest
import org.mozilla.geckoview.WebResponse
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer

/** Engine Gecko (chỉ có ở bản full): tạo lần đầu cần, giữ tới khi tắt app. */
internal object GeckoEngine {
    /** GeckoView 141 chạy từ Android 5 (như app); để sẵn chỗ chặn nếu bản Gecko sau đòi cao hơn. */
    val supported: Boolean get() = Build.VERSION.SDK_INT >= 21

    private var runtime: GeckoRuntime? = null
    private var executor: GeckoWebExecutor? = null
    /** Cổng SOCKS riêng cho Gecko (cố định suốt phiên; đi theo cài đặt mạng hiện tại của app lúc mở từng kết nối). */
    private var bridge: Socks5Bridge? = null
    /** Chỉ dùng trên luồng giao diện. */
    private val passed = HashSet<String>()
    private val blockedUntil = HashMap<String, Long>()
    private val opening = HashMap<String, MutableList<(Throwable?) -> Unit>>()

    private fun runtime(): GeckoRuntime {
        runtime?.let { return it }
        val app = WebFetch.app
        val b = bridge ?: runCatching {
            Socks5Bridge({ AppProxy.currentConfig() ?: RouteConfig(null, false) }, { (Prefs.sites + Prefs.baseUrl).mapNotNull { Site.hostOf(it) } })
        }.getOrNull().also { bridge = it }
        // Tuỳ chọn của Gecko (prefs) đọc lúc khởi động: đi qua cổng SOCKS nội bộ, để cổng phân giải tên miền (DNS mã hoá / của proxy)
        val cfg = File(app.filesDir, "geckoview-config.yaml")
        cfg.writeText(
            buildString {
                append("prefs:\n")
                if (b != null) {
                    append("  network.proxy.type: 1\n")
                    append("  network.proxy.socks: \"127.0.0.1\"\n")
                    append("  network.proxy.socks_port: ${b.port}\n")
                    append("  network.proxy.socks_version: 5\n")
                    append("  network.proxy.socks_remote_dns: true\n")
                    append("  network.proxy.allow_hijacking_localhost: false\n")
                }
                append("  media.autoplay.default: 5\n") // không tự phát âm thanh / video
                append("  permissions.default.image: 2\n") // trang chủ mở để qua lớp chặn: khỏi tải ảnh
                append("  browser.cache.disk.enable: false\n")
                // Gecko ở đây không vẽ gì lên màn hình: khỏi tiến trình GPU, tiến trình chạy sẵn — nhẹ RAM cho TV box
                append("  layers.gpu-process.enabled: false\n")
                append("  dom.ipc.processPrelaunch.enabled: false\n")
                append("  dom.ipc.processCount: 1\n")
                append("  dom.ipc.keepProcessesAlive.web: 0\n") // đóng session (đã qua lớp chặn) là trả RAM của tiến trình trang
                append("  browser.sessionhistory.max_total_viewers: 0\n")
                append("env:\n")
                append("  MOZ_CRASHREPORTER_DISABLE: \"1\"\n") // không cần tiến trình báo lỗi (crashhelper)
            },
        )
        val settings = GeckoRuntimeSettings.Builder()
            .configFilePath(cfg.absolutePath)
            .consoleOutput(false)
            .javaScriptEnabled(true)
            .remoteDebuggingEnabled(BuildConfig.DEBUG)
            .build()
        val r = GeckoRuntime.create(app, settings)
        runtime = r
        executor = GeckoWebExecutor(r)
        Log.d(WebFetch.TAG, "Gecko khởi động (cổng SOCKS riêng ${b?.port ?: "không có"})")
        return r
    }

    fun invalidate(host: String) {
        WebFetch.main.post { passed.remove(host) }
    }

    /** Chờ tới khi trình duyệt Gecko đã qua lớp chặn của trang (lần đầu mở trang chủ; các lần sau trả ngay). */
    fun pass(host: String) = WebFetch.onMain<Unit>(WebFetch.PASS_MS + 10_000) { done ->
        val until = blockedUntil[host] ?: 0
        when {
            System.currentTimeMillis() < until -> done(Result.failure(WebFetch.BlockedError(host)))
            host in passed -> done(Result.success(Unit))
            else -> {
                val waiting = opening[host]
                val cb: (Throwable?) -> Unit = { e -> done(if (e == null) Result.success(Unit) else Result.failure(e)) }
                if (waiting != null) waiting += cb else {
                    opening[host] = mutableListOf(cb)
                    open(host)
                }
            }
        }
    }

    private fun finish(host: String, e: Throwable?) {
        if (e == null) passed += host
        opening.remove(host)?.forEach { it(e) }
    }

    private fun open(host: String) {
        val r = try {
            runtime()
        } catch (e: Throwable) {
            Log.d(WebFetch.TAG, "Không khởi động được Gecko: $e")
            return finish(host, IOException("Không khởi động được engine Gecko: ${e.message}"))
        }
        val t0 = System.currentTimeMillis()
        var title = ""
        var titleAt = t0
        var stopped = false
        val s = GeckoSession(GeckoSessionSettings.Builder().usePrivateMode(false).build())
        s.contentDelegate = object : GeckoSession.ContentDelegate {
            override fun onTitleChange(session: GeckoSession, t: String?) {
                if (t.orEmpty() != title) titleAt = System.currentTimeMillis()
                title = t.orEmpty()
            }
        }
        s.progressDelegate = object : GeckoSession.ProgressDelegate {
            override fun onPageStart(session: GeckoSession, url: String) {
                stopped = false
            }

            override fun onPageStop(session: GeckoSession, success: Boolean) {
                stopped = true
            }
        }
        s.open(r)
        s.setActive(true)
        s.loadUri("https://$host/")
        fun done(e: Throwable?) {
            try {
                s.close()
            } catch (_: Throwable) {
            }
            finish(host, e)
        }
        fun probe() {
            val ms = System.currentTimeMillis() - t0
            when {
                title.startsWith("Attention Required", ignoreCase = true) -> {
                    Log.d(WebFetch.TAG, "$host: Cloudflare chặn hẳn cả Gecko")
                    blockedUntil[host] = System.currentTimeMillis() + WebFetch.BLOCKED_MS
                    done(WebFetch.BlockedError(host))
                }
                title.isNotEmpty() && !title.startsWith("Just a moment", ignoreCase = true) && !title.startsWith("http") &&
                    !title.equals(host, ignoreCase = true) && (stopped || System.currentTimeMillis() - titleAt > 1500) -> {
                    Log.d(WebFetch.TAG, "$host: Gecko đã qua lớp chống bot ($ms ms, «$title»)")
                    done(null)
                }
                ms > WebFetch.PASS_MS -> {
                    Log.d(WebFetch.TAG, "$host: Gecko chưa qua lớp chặn sau ${WebFetch.PASS_MS / 1000} giây («$title»)")
                    done(WebFetch.ChallengeError(host))
                }
                else -> WebFetch.main.postDelayed({ probe() }, 400)
            }
        }
        WebFetch.main.postDelayed({ probe() }, 400)
    }

    /** Một yêu cầu qua mạng của Gecko (chung cookie với session đã qua lớp chặn). */
    fun request(url: String, method: String, body: String?, headers: Map<String, String>): WebFetch.Raw {
        val result = WebFetch.onMain<GeckoResult<WebResponse>>(10_000) { done ->
            val b = WebRequest.Builder(url).method(method)
            for ((k, v) in headers) {
                when {
                    k.equals("Referer", true) -> b.referrer(v)
                    k.equals("User-Agent", true) || k.equals("Cookie", true) || k.equals("Accept-Encoding", true) -> {}
                    else -> b.addHeader(k, v)
                }
            }
            if (body != null) {
                val bytes = body.toByteArray(Charsets.UTF_8)
                b.body(ByteBuffer.allocateDirect(bytes.size).put(bytes).also { it.flip() })
            }
            done(Result.success(executor!!.fetch(b.build(), GeckoWebExecutor.FETCH_FLAGS_NONE)))
        }
        val resp = try {
            result.poll(WebFetch.CALL_MS)!!
        } catch (e: Throwable) {
            throw IOException("Gecko đọc $url lỗi: ${e.message ?: e.javaClass.simpleName}")
        }
        val data = resp.body?.use { it.readBytes() } ?: ByteArray(0)
        fun header(name: String) = resp.headers.entries.firstOrNull { it.key.equals(name, true) }?.value
        return WebFetch.Raw(resp.statusCode, resp.uri, header("Content-Type"), header("cf-mitigated"), data)
    }
}
