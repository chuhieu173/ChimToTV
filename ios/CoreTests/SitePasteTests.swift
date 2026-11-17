import XCTest

/// Dán nhiều trang phim một lần (Cài đặt / «Chọn trang phim»): tách, rút về gốc trang, bỏ trùng; chỉ tên miền giả.
final class SitePasteTests: XCTestCase {
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "SitePasteTests-\(UUID().uuidString)"
        Prefs.store = UserDefaults(suiteName: suite)!
        Prefs.reload()
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        Prefs.store = .standard
        Prefs.reload()
        super.tearDown()
    }

    func testSplitsAndRoots() {
        let text = "phim-a.example\n  https://phim-b.example/phim/abc?x=1#t  \n\n# ghi chú phim-c.example\n" +
            "«Trang 1»: <http://WWW.Phim-D.example:8080/xem>, chữ thường\r\nwww.phim-a.example/\nhttp://phim-b.example\n" +
            "bản 1.5 và 2.21 [phim-e.example]. bad..host .an.example localhost\nhttp://phim-d.example:9090/"
        XCTAssertEqual(Prefs.splitSites(text), [
            "https://phim-a.example",
            "https://phim-b.example",
            "http://www.phim-d.example:8080",
            "https://phim-e.example",
            "http://phim-d.example:9090",
        ])
        // «bad..host» là tên sai; số bản, «.an.example», «localhost»: bỏ qua không báo
        XCTAssertEqual(Prefs.parseSites(text).invalid, 1)
        XCTAssertTrue(Prefs.splitSites("  \n# chỉ chú thích\nkhông có tên miền").isEmpty)
        XCTAssertEqual(Prefs.siteKey("https://WWW.Phim-A.example/"), "phim-a.example")
        XCTAssertEqual(Prefs.siteKey("www.phim-a.example"), "phim-a.example")
        XCTAssertEqual(Prefs.siteKey("http://phim-a.example:8443/x"), "phim-a.example:8443")
        XCTAssertEqual(Prefs.siteRoot("https://phim-a.example:8443/a/b?c"), "https://phim-a.example:8443")
        XCTAssertNil(Prefs.siteRoot("https://bad..host"))
    }

    func testAddSitesSkipsExisting() {
        Prefs.sites = ["https://phim-a.example", "https://www.phim-b.example"]
        let before = Prefs.baseUrl
        let r = Prefs.addSites("http://phim-a.example/\nphim-b.example\nphim-c.example\nhttps://phim-d.example/x\nphim-c.example")
        XCTAssertEqual(r.added, ["https://phim-c.example", "https://phim-d.example"])
        XCTAssertEqual(r.existing, 2)
        XCTAssertEqual(r.invalid, 0)
        XCTAssertEqual(Prefs.sites, ["https://phim-a.example", "https://www.phim-b.example", "https://phim-c.example", "https://phim-d.example"])
        XCTAssertEqual(Prefs.baseUrl, before) // không đổi trang đang dùng
        let none = Prefs.addSites("phim-a.example\nphim-c.example")
        XCTAssertTrue(none.added.isEmpty)
        XCTAssertEqual(none.existing, 2)
    }
}
