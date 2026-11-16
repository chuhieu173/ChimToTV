package vn.chimto.tv

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.IOException
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Đọc trang bật lớp chống bot của Cloudflare (hoathinh3d.pw từ 14/11/2026: 403 «Just a moment…» với mọi trình tải không phải
 * trình duyệt — cả trang, API, ảnh; còn WebView của Android thì bị chặn hẳn «you have been blocked»). Chỉ những trang này đi qua
 * engine **Gecko** (GeckoView — engine của Firefox, gói kèm bản full); trang bình thường vẫn như cũ (HttpURLConnection + WebView).
 *
 * Bản lite không đóng gói GeckoView để giữ APK ~1.25 MB (`supported == false`).
 */
object WebFetch {
    class Raw(val code: Int, val url: String, val type: String?, val cf: String?, val data: ByteArray)

    /** Trang bật chống bot mà app chưa đọc được. */
    class ChallengeError(val host: String) :
        IOException("Trang $host đang bật lớp chống bot của Cloudflare — app chưa đọc được (thử lại sau, hoặc xem phim này ở nguồn khác).")

    /** Cloudflare của trang chặn hẳn cả engine Gecko — quyết định của chủ trang. */
    class BlockedError(val host: String) :
        IOException("Trang $host chặn app này (Cloudflare «you have been blocked») — xem phim này ở nguồn khác, vd KKPhim.")

    internal const val TAG = "ChimToWeb"
    const val KEEP_MS = 12 * 3600_000L
    internal const val PASS_MS = 30_000L
    internal const val CALL_MS = 45_000L
    internal const val BLOCKED_MS = 30 * 60_000L
    val supported: Boolean get() = GeckoEngine.supported

    private val hosts = ConcurrentHashMap<String, Long>()
    internal lateinit var app: Context
        private set
    internal val main by lazy { Handler(Looper.getMainLooper()) }

    fun init(context: Context) {
        app = context.applicationContext
    }

    fun hostOf(url: String): String = try {
        URI(url).host?.lowercase().orEmpty()
    } catch (e: Exception) {
        ""
    }

    fun remember(host: String, now: Long = System.currentTimeMillis()) {
        if (host.isNotEmpty()) hosts[host.lowercase()] = now
    }

    /** Trang của địa chỉ này đang bị nhớ là chặn (trong 12 giờ). */
    fun needs(url: String, now: Long = System.currentTimeMillis()): Boolean {
        val t = hosts[hostOf(url)] ?: return false
        return now - t in 0 until KEEP_MS
    }

    fun forgetAll() = hosts.clear()

    /**
     * Trả lời này là lớp chặn của Cloudflare (không phải lỗi thật của trang): đầu thư `cf-mitigated: challenge`, hoặc 403 / 503 mà
     * nội dung là trang «Just a moment…» / mã của trang chặn (`_cf_chl_opt`). Cùng luật với lõi Rust (web_fetch.rs).
     */
    fun isChallenge(code: Int, cfMitigated: String?, body: ByteArray?): Boolean {
        if (cfMitigated?.trim().equals("challenge", ignoreCase = true)) return true
        if (code != 403 && code != 503) return false
        val head = body?.let { String(it, 0, minOf(it.size, 8192), Charsets.UTF_8).lowercase() } ?: return false
        return "<title>just a moment" in head || "_cf_chl_opt" in head || "/cdn-cgi/challenge-platform/h/" in head
    }

    /** Trang chặn hẳn của Cloudflare («Attention Required! … Sorry, you have been blocked»). */
    fun isBlockPage(code: Int, body: ByteArray?): Boolean {
        if (code != 403) return false
        val head = body?.let { String(it, 0, minOf(it.size, 8192), Charsets.UTF_8).lowercase() } ?: return false
        return "<title>attention required! | cloudflare" in head || "cf-error-details" in head
    }

    /** Đọc tối đa 8 KB đầu của luồng lỗi (đủ để nhận ra trang chặn). */
    fun head(input: java.io.InputStream?): ByteArray? = input?.use {
        val buf = ByteArray(8192)
        var n = 0
        while (n < buf.size) {
            val r = it.read(buf, n, buf.size - n)
            if (r < 0) break
            n += r
        }
        buf.copyOf(n)
    }

    /**
     * Đọc qua Gecko — gọi từ luồng nền (chờ tới khi xong). Lớp chặn quay lại giữa chừng (cookie hết hạn) → qua lại lớp chặn,
     * thử thêm một lần.
     */
    fun fetch(url: String, method: String = "GET", body: String? = null, headers: Map<String, String> = emptyMap()): Raw {
        check(Looper.myLooper() != Looper.getMainLooper()) { "WebFetch.fetch không được chạy trên luồng giao diện" }
        val host = hostOf(url)
        if (!supported) throw ChallengeError(host)
        repeat(2) { attempt ->
            GeckoEngine.pass(host)
            val r = GeckoEngine.request(url, method, body, headers)
            if (!isChallenge(r.code, r.cf, r.data)) {
                if (isBlockPage(r.code, r.data)) throw BlockedError(host)
                return r
            }
            if (attempt == 0) GeckoEngine.invalidate(host)
        }
        throw ChallengeError(host)
    }

    /** Http.Response như Http.get / post (lỗi HTTP ≥ 400 → Http.HttpError). */
    fun response(url: String, method: String = "GET", body: String? = null, headers: Map<String, String> = emptyMap()): Http.Response {
        val r = fetch(url, method, body, headers)
        Log.d(TAG, "$url → ${r.code} qua Gecko, ${r.data.size} byte")
        if (r.code >= 400) throw Http.HttpError(r.code)
        return Http.Response(r.url.ifEmpty { url }, r.code, r.data.toString(Http.charsetOf(r.type)))
    }

    /** Chạy trên luồng giao diện, chờ ở luồng nền. */
    internal fun <T> onMain(timeoutMs: Long, start: (done: (Result<T>) -> Unit) -> Unit): T {
        val latch = CountDownLatch(1)
        val out = AtomicReference<Result<T>>()
        main.post {
            try {
                start { r -> if (out.compareAndSet(null, r)) latch.countDown() }
            } catch (e: Throwable) {
                if (out.compareAndSet(null, Result.failure(e))) latch.countDown()
            }
        }
        if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) throw IOException("Gecko không trả lời")
        return out.get().getOrThrow()
    }
}
