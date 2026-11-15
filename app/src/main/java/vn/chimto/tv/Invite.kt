package vn.chimto.tv

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Bundle
import android.util.AttributeSet
import android.util.TypedValue
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast

/**
 * Cài app lên tivi khác bằng app Downloader (AFTVnews): người mới chỉ cần cài Downloader trên tivi rồi nhập CODE. APK_URL:
 * link cố định luôn tải bản TV mới nhất (mỗi release TV đính kèm tệp tên ConBangTV.apk, xem release.ps1). Mã do aftv.news cấp
 * trỏ vào link tên cũ …/ChimToTV.apk (tạo trước khi đổi tên tệp, 13/11/2026) — mọi release TV vẫn đính kèm cả tệp đó, link nào
 * cũng tải cùng một tệp. Đổi mã / link thì sửa đủ năm chỗ: ở đây, bản iPad (Invite.swift), bản Windows (Invite.cs),
 * release.ps1 và README (mục «Cài trên Android TV bằng Downloader»).
 */
object Invite {
    const val TITLE = "Mời bạn bè cài app"
    const val CODE = "9192365"
    const val SHORT_URL = "aftv.news/$CODE"
    const val APK_URL = "https://github.com/conbangtv/ChimToTV/releases/latest/download/ConBangTV.apk"

    /** Trang hướng dẫn tiếng Việt (mục Downloader của README) — mã QR trên màn mở trang này. */
    const val GUIDE_URL = "https://github.com/conbangtv/ChimToTV/blob/main/README.md#downloader"

    /** Tin nhắn gửi cho người quen (nút «Gửi hướng dẫn…» trên điện thoại / máy tính bảng). */
    val MESSAGE = """
        Cài Côn Bằng TV trên tivi Android:
        1. Trên tivi mở CH Play, cài app Downloader (của AFTVnews).
        2. Mở Downloader, nhập $CODE rồi bấm Go.
        3. Tải xong chọn Install. Lần đầu tivi hỏi cho phép Downloader cài ứng dụng thì cho phép.
        Cài xong app tự cập nhật các bản sau.
        Hướng dẫn: $GUIDE_URL
    """.trimIndent()

    /**
     * Mã QR của GUIDE_URL, vẽ sẵn (mức sửa lỗi M; mỗi chuỗi một hàng, '1' = ô đen) — app không cần thư viện QR. Đổi GUIDE_URL
     * thì chạy InviteTest: test dựng lại bằng ZXing, báo lệch và in ra các hàng mới để dán vào đây; test thứ hai đọc lại mã
     * như điện thoại.
     */
    val QR: List<String> = listOf(
        "1111111000100001100000110000101111111",
        "1000001001110111100010100101101000001",
        "1011101010111011001001000010001011101",
        "1011101010100010010010101111001011101",
        "1011101010110100111011010000101011101",
        "1000001010011100010010000011001000001",
        "1111111010101010101010101010101111111",
        "0000000011010110011011001000100000000",
        "1011111001100100100101001110001111100",
        "1001000000110001011011010100001101010",
        "0110101110101111110100101111011100011",
        "0111010010000101000111100011110000001",
        "0010011101011011000100101111011011111",
        "1101010010110110100110110100000100000",
        "1101001011001111101010101111011111011",
        "0101110111101000100000011010001110011",
        "0100011001000100001111101111011000110",
        "0010100111011101100001010110101101110",
        "1010101110110100000011100011100100011",
        "0100010000000010101001001011111100001",
        "1111101001010110000000101100011011100",
        "0110110010101000110111110000110001000",
        "1111011100010001010001001111110111011",
        "1011110111111101111001110011111110010",
        "1010011101101010100101011111011000110",
        "1100100000000001001011110100101100100",
        "1001001010100111110100100111011011111",
        "1010100101111111001111010010101001001",
        "1010001101000111011100011110111111111",
        "0000000010001110101110010100100011000",
        "1111111000111011001010100110101010101",
        "1000001011010000000100010000100011000",
        "1011101010001111001011111111111110101",
        "1011101010011001110000010001011010101",
        "1011101011110110010010101101100000111",
        "1000001001001000100001100011111010001",
        "1111111011011110010001111111011010011",
    )
}

/** Vẽ Invite.QR: nền trắng, lề trắng 4 ô quanh mã (máy đọc cần), mỗi ô một số nguyên điểm ảnh cho nét. */
class QrView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    private val dark = Paint().apply { color = Color.BLACK; isAntiAlias = false }
    private val rows = Invite.QR

    override fun onMeasure(widthSpec: Int, heightSpec: Int) {
        super.onMeasure(widthSpec, heightSpec)
        val side = minOf(measuredWidth, measuredHeight)
        setMeasuredDimension(side, side)
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(Color.WHITE)
        if (rows.isEmpty()) return
        val cells = rows.size + 2 * QUIET
        val cell = minOf(width, height) / cells
        if (cell <= 0) return
        val left = (width - cell * rows.size) / 2f
        val top = (height - cell * rows.size) / 2f
        for ((y, row) in rows.withIndex()) {
            for ((x, c) in row.withIndex()) {
                if (c == '1') canvas.drawRect(left + x * cell, top + y * cell, left + (x + 1) * cell, top + (y + 1) * cell, dark)
            }
        }
    }

    private companion object {
        const val QUIET = 4
    }
}

/**
 * Màn «Mời bạn bè cài app» (menu bên trái và Cài đặt → Liên hệ): mã Downloader thật to, ba bước cài, mã QR mở trang hướng
 * dẫn để khách chụp bằng điện thoại. Chỉ có nút «Đóng»; Back cũng đóng.
 */
class InviteActivity : BaseActivity() {
    companion object {
        fun open(ctx: Context) {
            ctx.startActivity(Intent(ctx, InviteActivity::class.java))
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_invite)
        findViewById<TextView>(R.id.inviteCode).text = Invite.CODE.chunked(1).joinToString(" ")
        findViewById<TextView>(R.id.inviteLinks).text =
            "Trên trình duyệt: ${Invite.SHORT_URL}\nLink tải trực tiếp: ${Invite.APK_URL.removePrefix("https://")}"
        findViewById<TextView>(R.id.btnInviteShare).apply {
            visibility = if (Screen.isTv(this@InviteActivity)) View.GONE else View.VISIBLE
            setOnClickListener { share() }
        }
        findViewById<TextView>(R.id.btnInviteClose).apply {
            setOnClickListener { finish() }
            requestFocus()
        }
        arrange()
    }

    /** Điện thoại / máy tính bảng: gửi cách cài (Invite.MESSAGE) qua app nhắn tin người xem chọn. */
    private fun share() {
        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, Invite.MESSAGE)
        try {
            startActivity(Intent.createChooser(send, "Gửi hướng dẫn cài app"))
        } catch (e: ActivityNotFoundException) {
            Toast.makeText(this, "Máy không có app nào để gửi — đọc mã ${Invite.CODE} cho bạn bè.", Toast.LENGTH_LONG).show()
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        arrange()
    }

    /** Màn ngang (TV, máy tính bảng): các bước bên trái, mã QR bên phải. Điện thoại cầm dọc: xếp dọc, lề và chữ nhỏ hơn. */
    private fun arrange() {
        val narrow = Screen.narrow(this)
        val d = resources.displayMetrics.density
        val pad = ((if (narrow) 16 else 48) * d).toInt()
        findViewById<View>(R.id.inviteRoot).setPadding(pad, ((if (narrow) 16 else 28) * d).toInt(), pad, ((if (narrow) 16 else 20) * d).toInt())
        findViewById<LinearLayout>(R.id.inviteContent).orientation = if (narrow) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
        findViewById<TextView>(R.id.inviteCode).setTextSize(TypedValue.COMPLEX_UNIT_SP, if (narrow) 44f else 64f)
        // Màn hẹp: dòng link dài chiếm hết đáy màn — bỏ (tin nhắn «Gửi hướng dẫn…» đã có link); nút «Đóng» co lại cho nút
        // «Gửi hướng dẫn…» đủ chỗ hiện hết chữ
        findViewById<View>(R.id.inviteLinks).visibility = if (narrow) View.GONE else View.VISIBLE
        findViewById<TextView>(R.id.btnInviteClose).apply {
            // android:minWidth trong layout đặt cả hai mức tối thiểu (của TextView và của View) — phải hạ cả hai
            val w = ((if (narrow) 0 else 140) * d).toInt()
            minWidth = w
            minimumWidth = w
        }
        findViewById<View>(R.id.inviteSteps).layoutParams = LinearLayout.LayoutParams(
            if (narrow) LinearLayout.LayoutParams.MATCH_PARENT else 0, LinearLayout.LayoutParams.WRAP_CONTENT, if (narrow) 0f else 1f,
        )
        findViewById<View>(R.id.inviteQrBox).layoutParams = LinearLayout.LayoutParams(
            if (narrow) LinearLayout.LayoutParams.MATCH_PARENT else (290 * d).toInt(), LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply {
            if (narrow) topMargin = (20 * d).toInt() else marginStart = (40 * d).toInt()
        }
    }
}
