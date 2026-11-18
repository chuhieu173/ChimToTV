import XCTest

/// Nhật ký che tài khoản trong link (cùng ca với TvLog của bản Android và log::redact của lõi Rust).
final class LogTests: XCTestCase {
    func testHidesCredentialsInLinks() {
        XCTAssertEqual(Log.redact("tải http://tv.example:8080/get.php?username=an&password=b1&type=m3u_plus lỗi"),
                       "tải http://tv.example:8080/get.php?username=***&password=***&type=m3u_plus lỗi")
        XCTAssertEqual(Log.redact("VTV1 (nguồn 1/2) http://tv.example/live/an/b1/123.ts"),
                       "VTV1 (nguồn 1/2) http://tv.example/live/***/***/123.ts")
        XCTAssertEqual(Log.redact("https://an:b1@tv.example/x.m3u?token=abc#t"), "https://***@tv.example/x.m3u?token=***#t")
        XCTAssertEqual(Log.redact("danh sách «Thử» — 467 kênh"), "danh sách «Thử» — 467 kênh")
    }
}
