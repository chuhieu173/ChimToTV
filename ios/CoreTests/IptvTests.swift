import XCTest

/// Truyền hình (IPTV): đọc M3U, tên kênh, giờ trận, XMLTV — cùng bộ thử với lõi Rust (linux/core/src/iptv.rs) và IptvParseTest.kt.
final class IptvTests: XCTestCase {
    private func read(_ text: String) -> (String?, [IptvEntry]) {
        let r = IptvReader()
        let e = text.components(separatedBy: "\n").compactMap { r.line($0) }
        return (r.epg, e)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Double { Double(IptvParse.daysFromCivil(y, m, d)) * 86400 }

    func testReadsExtinf() {
        let (epg, e) = read(
            "\u{FEFF}#EXTM3U url-tvg=\"https://a.example/epg.xml,https://b.example/epg.xml.gz\"\n" +
            "#EXTINF:-1 tvg-id=\"vtv1.vn\" tvg-logo=\"http://l/1.png\" group-title=\"Tin tức, thời sự\",VTV1 HD\n" +
            "#EXTVLCOPT:http-referrer=https://ref.example/\n#EXTVLCOPT:http-user-agent=Player/1.0\nhttps://s.example/vtv1.m3u8\n" +
            "#EXTINF:-1,Kênh B\n#EXTGRP:Giải trí\nhttp://s.example/b.m3u8|Referer=https%3A%2F%2Fr.example%2F&User-Agent=UA2\n")
        XCTAssertEqual(epg, "https://a.example/epg.xml")
        XCTAssertEqual(e.count, 2)
        XCTAssertEqual(e[0].name, "VTV1 HD")
        XCTAssertEqual(e[0].group, "Tin tức, thời sự")
        XCTAssertEqual(e[0].attrs["tvg-id"], "vtv1.vn")
        XCTAssertEqual(e[0].referer, "https://ref.example/")
        XCTAssertEqual(e[0].ua, "Player/1.0")
        XCTAssertEqual(e[1].group, "Giải trí")
        XCTAssertEqual(e[1].url, "http://s.example/b.m3u8")
        XCTAssertEqual(e[1].referer, "https://r.example/")
        XCTAssertEqual(e[1].ua, "UA2")
    }

    func testNamesAndKinds() {
        XCTAssertEqual(IptvParse.norm("VTV1 HD"), "vtv1")
        XCTAssertEqual(IptvParse.norm("An Ninh TV HD (1080p) [Geo-blocked]"), "anninhtv")
        XCTAssertEqual(IptvParse.norm("Đồng Tháp FHD"), "dongthap")
        XCTAssertEqual(IptvParse.displayName("|ALB| SUPER SPORT 1 HD"), "SUPER SPORT 1 HD")
        XCTAssertEqual(IptvParse.displayName("DE| ZDF"), "ZDF")
        XCTAssertEqual(IptvParse.displayName("Can Tho TV 2 (1080p) [Geo-blocked]"), "Can Tho TV 2")
        XCTAssertTrue(IptvParse.isPlaceholder("https://x.example/static/no-signal/low.m3u8"))
        XCTAssertEqual(IptvParse.sourceRank("http://a/b.flv?t=1"), 1)
        XCTAssertTrue(IptvParse.isVod("http://h:80/series/u/p/1.mkv"))
        XCTAssertFalse(IptvParse.isVod("http://h:80/u/p/3396"))
        XCTAssertTrue(IptvParse.isRadio([:], groupNorm: IptvParse.norm("KÊNH RADIO NƯỚC NGOÀI"), ext: "m3u8"))
        XCTAssertEqual(IptvParse.nameFromFile("4k viptv-playlist---2026-11-11T131814-437.m3u"), "4k viptv-playlist")
        XCTAssertEqual(IptvParse.nameFromUrl("http://short.example/ab"), "short.example")
        XCTAssertEqual(IptvParse.nameFromUrl("http://h.example/lists/the_best.m3u"), "the best")
    }

    func testKickoffs() {
        let now = day(2026, 11, 16) + 5 * 3600
        let n = "20:00 16/11 ⚽ Việt Nam vs Thái Lan (BLV Quang Huy) [hls]"
        let k = IptvParse.kickoff(n, now: now)!
        XCTAssertEqual(k.at, day(2026, 11, 16) + 13 * 3600)
        XCTAssertEqual(IptvParse.matchName(n, k), "⚽ Việt Nam vs Thái Lan (BLV Quang Huy)")
        XCTAssertEqual(IptvParse.kickoff("16/11 02h45 Real - Barca", now: now)!.at, day(2026, 11, 15) + 19 * 3600 + 45 * 60)
        XCTAssertEqual(IptvParse.kickoff("19:30 01/01 A vs B", now: day(2026, 12, 31))!.at, day(2027, 1, 1) + 12 * 3600 + 1800)
        XCTAssertNil(IptvParse.kickoff("VTV1 HD", now: now))
        XCTAssertNil(IptvParse.kickoff("120:00 16/11 x", now: now))
        XCTAssertTrue(IptvParse.isMatchName(n))
        XCTAssertFalse(IptvParse.isMatchName("VTV1 HD 16/11"))
        XCTAssertEqual(IptvParse.matchState(kick: 1000, dur: 130, now: 1000 - 3600), .later)
        XCTAssertEqual(IptvParse.matchState(kick: 1000, dur: 130, now: 1001), .live)
        XCTAssertEqual(IptvParse.oldEmoji("🥎 A  🟢 vs B"), "🎾 A vs B")
    }

    func testBuildsAndMerges() {
        let m3u = "#EXTM3U\n#EXTINF:-1 group-title=\"Thể thao\",20:00 16/11 ⚽ A vs B (BLV X) [hls]\nhttp://a/x.m3u8\n" +
            "#EXTINF:-1 group-title=\"Thể thao\",20:00 16/11 ⚽ A vs B (BLV X) [flv]\n#EXTVLCOPT:http-referrer=https://r/\nhttp://a/x.flv\n" +
            "#EXTINF:-1 group-title=\"Thể thao\",20:00 16/11 ⚽ A vs B (BLV Y) [hls]\nhttp://a/y.m3u8\n" +
            "#EXTINF:-1 group-title=\"VTV\",VTV1 HD\nhttp://v/1.m3u8\n#EXTINF:-1 group-title=\"VTV\",VTV1 FHD\nhttp://v/1b.m3u8\n" +
            "#EXTINF:-1 group-title=\"Radio\",VOV1\nhttp://r/vov1.aac\n"
        let l = IptvLoaded.build(listId: "t", lines: IptvStringLines(m3u), now: day(2026, 11, 16))
        XCTAssertEqual(l.channels.count, 4)
        XCTAssertTrue(l.hasMatches)
        XCTAssertEqual(l.channels[0].urls, ["http://a/x.m3u8", "http://a/x.flv"])
        XCTAssertEqual(l.channels[0].headers(for: "http://a/x.flv").referer, "https://r/")
        XCTAssertNil(l.channels[0].headers(for: "http://a/x.m3u8").referer)
        XCTAssertEqual(l.channels[0].dur, 130)
        XCTAssertEqual(l.channels[2].urls.count, 2)
        XCTAssertEqual(l.channels[2].k, "vtv1")
        XCTAssertTrue(l.channels[3].radio)
        XCTAssertEqual(l.groups, ["Thể thao", "VTV", "Radio"])
        XCTAssertNotNil(l.byKey("vtv1"))
    }

    func testXmltv() throws {
        let x = """
            <?xml version="1.0"?><tv><!-- a > b --><channel id="vtv1.vn"><display-name>VTV1</display-name></channel>
            <channel id="x2"><display-name lang="vi">VTV2 HD</display-name></channel>
            <programme start="20261116190000 +0700" stop="20261116193000 +0700" channel="vtv1.vn"><title>Thời sự &amp; tin</title></programme>
            <programme start="20261116190000 +0700" stop="20261116200000 +0700" channel="x2"><title lang="vi">Phim</title><desc>…</desc></programme>
            <programme start="20261116190000 +0700" channel="other"><title>Bỏ</title></programme></tv>
            """
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("iptv-test-\(UUID().uuidString).xml")
        try x.write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        let p = IptvParse.parseXmltv(IptvByteReader(url: f)!, tids: ["vtv1.vn"], keys: ["vtv2"], from: 0, to: 1e12)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p["vtv1.vn"]?.first?.t, "Thời sự & tin")
        XCTAssertEqual(p["n:vtv2"].map { $0[0].e - $0[0].s }, 3600)
        XCTAssertEqual(IptvParse.xmltvTime("20261116190000 +0700"), day(2026, 11, 16) + 12 * 3600)
        XCTAssertTrue(IptvParse.isPlaceholderPlaylist("#EXTM3U\n#EXTINF:10.0,\na.ts\n#EXT-X-ENDLIST\n"))
        XCTAssertFalse(IptvParse.isPlaceholderPlaylist("#EXTM3U\n#EXTINF:10.0,\na.ts\n"))
    }

    func testGzip() throws {
        // «hello\n» nén gzip (tạo sẵn bằng gzip -n)
        let gz: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0xE7, 0x02, 0x00,
                           0x20, 0x30, 0x3A, 0x36, 0x06, 0x00, 0x00, 0x00]
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("iptv-test-\(UUID().uuidString).gz")
        try Data(gz).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        let out = try XCTUnwrap(Iptv.gunzipIfNeeded(f))
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "hello\n")
    }
}
