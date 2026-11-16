package vn.chimto.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class UpdaterTest {
    @Test
    fun pickApkPrefersDeviceAbi() {
        val assets = listOf(
            "ConBangTV-2.20-armeabi-v7a.apk",
            "ConBangTV-2.20-arm64-v8a.apk",
            "ConBangTV.apk",
        )
        assertEquals(1, Updater.pickApk(assets, arrayOf("arm64-v8a", "armeabi-v7a")))
        assertEquals(0, Updater.pickApk(assets, arrayOf("armeabi-v7a", "armeabi")))
    }

    @Test
    fun pickApkFallsBackToUniversalOrFirst() {
        val mixed = listOf("ConBangTV-2.20-arm64-v8a.apk", "ConBangTV.apk")
        assertEquals(1, Updater.pickApk(mixed, arrayOf("armeabi-v7a")))

        val legacy = listOf("ConBangTV-2.19.apk", "ConBangTV.apk", "ChimToTV.apk")
        assertEquals(0, Updater.pickApk(legacy, arrayOf("arm64-v8a", "armeabi-v7a")))

        assertNull(Updater.pickApk(emptyList(), arrayOf("arm64-v8a")))
    }
}
