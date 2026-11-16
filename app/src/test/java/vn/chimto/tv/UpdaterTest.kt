package vn.chimto.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class UpdaterTest {
    @Test
    fun pickApkPrefersDeviceAbiForFull() {
        val assets = listOf(
            "ConBangTV-2.20-lite.apk",
            "ConBangTV-2.20-armeabi-v7a.apk",
            "ConBangTV-2.20-arm64-v8a.apk",
            "ConBangTV.apk",
        )
        assertEquals(2, Updater.pickApk(assets, arrayOf("arm64-v8a", "armeabi-v7a"), hasGecko = true))
        assertEquals(1, Updater.pickApk(assets, arrayOf("armeabi-v7a", "armeabi"), hasGecko = true))
    }

    @Test
    fun pickApkPrefersLiteForLiteBuild() {
        val assets = listOf(
            "ConBangTV-2.20.apk",
            "ConBangTV-2.20-armeabi-v7a.apk",
            "ConBangTV-2.20-arm64-v8a.apk",
            "ConBangTV-2.20-lite.apk",
        )
        assertEquals(3, Updater.pickApk(assets, arrayOf("arm64-v8a", "armeabi-v7a"), hasGecko = false))
    }

    @Test
    fun pickApkFallsBackToUniversalOrFirst() {
        val mixed = listOf("ConBangTV-2.20-arm64-v8a.apk", "ConBangTV.apk")
        assertEquals(1, Updater.pickApk(mixed, arrayOf("armeabi-v7a"), hasGecko = true))

        val legacy = listOf("ConBangTV-2.19.apk", "ConBangTV.apk", "ChimToTV.apk")
        assertEquals(0, Updater.pickApk(legacy, arrayOf("arm64-v8a", "armeabi-v7a"), hasGecko = true))
        assertEquals(0, Updater.pickApk(legacy, arrayOf("arm64-v8a", "armeabi-v7a"), hasGecko = false))

        assertNull(Updater.pickApk(emptyList(), arrayOf("arm64-v8a"), hasGecko = true))
    }
}
