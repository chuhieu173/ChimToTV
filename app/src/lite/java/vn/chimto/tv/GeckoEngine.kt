package vn.chimto.tv

/** Bản lite không đóng gói GeckoView để giữ APK ~1.25 MB. */
internal object GeckoEngine {
    val supported: Boolean get() = false

    fun invalidate(host: String) {}

    fun pass(host: String): Unit = throw WebFetch.ChallengeError(host)

    fun request(url: String, method: String, body: String?, headers: Map<String, String>): WebFetch.Raw =
        throw WebFetch.ChallengeError(WebFetch.hostOf(url))
}
