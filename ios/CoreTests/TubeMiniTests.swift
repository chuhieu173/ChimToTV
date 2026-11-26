import XCTest

/// TubeMini: đọc XML của tubemini-server (feed Atom kiểu GData + phần tử tm:) — mẫu theo docs/API.md của dự án TubeMini.
final class TubeMiniTests: XCTestCase {
    func testParsesVideoFeedWithNextLink() {
        let xml = """
        <?xml version='1.0' encoding='UTF-8'?>
        <feed xmlns='http://www.w3.org/2005/Atom' xmlns:media='http://search.yahoo.com/mrss/' xmlns:yt='http://x/schemas/2007'>
          <title>Tìm kiếm</title>
          <link rel='next' href='http://may:8080/feeds/api/videos?q=a&amp;continuation=abc'/>
          <entry>
            <id>tag:youtube.com,2008:video:dQw4w9WgXcQ</id>
            <published>2026-11-15T08:03:22.000Z</published>
            <title>Rick &#38; Roll</title>
            <author><name>Rick Astley</name><uri>http://may:8080/feeds/api/users/UCuAX</uri><yt:userId>UCuAX</yt:userId></author>
            <media:group>
              <media:title>Rick &#38; Roll</media:title>
              <media:thumbnail url='https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg' yt:name='mqdefault'/>
              <yt:duration seconds='213'/>
              <yt:videoid>dQw4w9WgXcQ</yt:videoid>
            </media:group>
            <yt:statistics viewCount='1650000000'/>
          </entry>
          <entry>
            <id>tag:youtube.com,2008:video:abcdefghijk</id>
            <title>Video hai</title>
            <author><name>Kênh B</name></author>
            <media:group><yt:uploaderId>UCbbb</yt:uploaderId><yt:duration seconds='65'/></media:group>
            <tm:position xmlns:tm='urn:tubemini:1' seconds='30'/>
          </entry>
        </feed>
        """
        let p = TubeXML.feed(Data(xml.utf8))
        XCTAssertEqual(p.videos.count, 2)
        XCTAssertEqual(p.videos[0].id, "dQw4w9WgXcQ")
        XCTAssertEqual(p.videos[0].title, "Rick & Roll")
        XCTAssertEqual(p.videos[0].author, "Rick Astley")
        XCTAssertEqual(p.videos[0].authorId, "UCuAX")
        XCTAssertEqual(p.videos[0].duration, 213)
        XCTAssertEqual(p.videos[0].views, 1_650_000_000)
        XCTAssertNotNil(p.videos[0].published)
        XCTAssertEqual(p.videos[1].authorId, "UCbbb")
        XCTAssertEqual(p.videos[1].position, 30)
        XCTAssertEqual(p.next, "http://may:8080/feeds/api/videos?q=a&continuation=abc")
        XCTAssertTrue(p.channels.isEmpty)
    }

    func testParsesChannelFeed() {
        let xml = """
        <feed xmlns='http://www.w3.org/2005/Atom' xmlns:media='http://search.yahoo.com/mrss/' xmlns:yt='http://x/schemas/2007'>
          <entry>
            <id>tag:youtube.com,2008:channel:UCabc</id>
            <title>HTV Tin Tức</title>
            <yt:channelId>UCabc</yt:channelId>
            <media:thumbnail url='https://yt3.ggpht.com/a=s88'/>
            <yt:channelStatistics subscriberCount='1260000'/>
          </entry>
        </feed>
        """
        let p = TubeXML.feed(Data(xml.utf8))
        XCTAssertEqual(p.videos.count, 0)
        XCTAssertEqual(p.channels, [TubeChannel(id: "UCabc", name: "HTV Tin Tức", avatar: "https://yt3.ggpht.com/a=s88", subscribers: 1_260_000)])
    }

    func testParsesStreamsAndPicksQuality() {
        let xml = """
        <tm:streams xmlns:tm="urn:tubemini:1" video_id="dQw4w9WgXcQ" expire="1794730000" available_in="4">
          <tm:stream quality="360" kind="mp4" url="https://rr3.googlevideo.com/videoplayback?a=1&amp;b=2"/>
          <tm:stream quality="720" kind="hls" url="http://may:8080/720/getvideo/dQw4w9WgXcQ" bandwidth="2566654"/>
          <tm:stream quality="1080" kind="hls" url="http://may:8080/1080/getvideo/dQw4w9WgXcQ" bandwidth="4690053"/>
          <tm:audio url="http://may:8080/getaudio/dQw4w9WgXcQ"/>
        </tm:streams>
        """
        let s = TubeXML.streams(Data(xml.utf8))
        XCTAssertEqual(s.availableIn, 4)
        XCTAssertEqual(s.audio, "http://may:8080/getaudio/dQw4w9WgXcQ")
        XCTAssertEqual(s.best(1080)?.quality, 1080)
        XCTAssertEqual(s.best(720)?.url, "http://may:8080/720/getvideo/dQw4w9WgXcQ")
        XCTAssertEqual(s.best(360)?.kind, "mp4")
        XCTAssertEqual(s.best(360)?.url, "https://rr3.googlevideo.com/videoplayback?a=1&b=2")
        // Không có mục nào ≤ 240: lấy mục nhỏ nhất
        XCTAssertEqual(s.best(240)?.quality, 360)
    }

    func testParsesHistoryAndError() {
        let h = TubeXML.attrs(Data(#"<tm:history xmlns:tm="urn:tubemini:1" video_id="x" position="754" duration="1347" watched=""/>"#.utf8), "tm:history")
        XCTAssertEqual(h["position"], "754")
        let e = TubeXML.attrs(Data(#"<tm:error xmlns:tm="urn:tubemini:1" code="no_stream" message="Không lấy được link."/>"#.utf8), "tm:history")
        XCTAssertEqual(e["code"], "no_stream")
    }

    func testAddressesAndTexts() {
        XCTAssertEqual(TubeMini.normalize(" may.local:8080/ "), "http://may.local:8080")
        XCTAssertEqual(TubeMini.normalize("https://tm.example"), "https://tm.example")
        XCTAssertEqual(TubeMini.normalize(""), "")
        // Máy chủ 0.7.0: tự chọn scheme như app TubeMini — trong nhà http, tên miền https; tên máy viết thường, mã giữ nguyên
        XCTAssertEqual(TubeMini.normalize("192.168.1.10:8080"), "http://192.168.1.10:8080")
        XCTAssertEqual(TubeMini.normalize("nas"), "http://nas")
        XCTAssertEqual(TubeMini.normalize("TM.Example.COM/u/K7pq-4xmz-9tbn/"), "https://tm.example.com/u/K7pq-4xmz-9tbn")
        XCTAssertEqual(TubeMini.normalize("tm.example.com:443/u/abc"), "https://tm.example.com:443/u/abc")
        XCTAssertEqual(TubeMini.normalize("tm.example.com:8080"), "http://tm.example.com:8080")
        XCTAssertEqual(TubeMini.normalize("box.lan"), "http://box.lan")
        XCTAssertEqual(TubeMini.normalize("//tm.example.com/u/abc"), "https://tm.example.com/u/abc")
        XCTAssertEqual(TubeMini.normalize("HTTP://Tm.Example.com/u/AbC"), "http://tm.example.com/u/AbC")
        XCTAssertEqual(TubeMini.otherScheme("http://tm.example.com/u/a"), "https://tm.example.com/u/a")
        XCTAssertEqual(TubeMini.otherScheme("https://192.168.1.10:8080"), "http://192.168.1.10:8080")
        // Hướng dẫn lấy mã: 3 bước đánh số rồi các lưu ý
        XCTAssertTrue(TubeMini.botGuide.hasPrefix("1. Bấm «Chat với bot» để mở thẳng khung chat @tube_mini_bot"))
        XCTAssertEqual(TubeMini.botApp.absoluteString, "tg://resolve?domain=tube_mini_bot")
        XCTAssertTrue(TubeMini.botGuide.contains("\n3. "))
        XCTAssertTrue(TubeMini.botGuide.contains("\n\n• Mất địa chỉ"))
        XCTAssertEqual(TubeMini.videoId(TubeMini.videoUrl("abc_DEF-123")), "abc_DEF-123")
        XCTAssertNil(TubeMini.videoId("tubemini://list/xyz"))
        XCTAssertTrue(TubeMini.isTubeUrl("tubemini://list/xyz"))
        XCTAssertEqual(TubeMini.durationText(213), "3:33")
        XCTAssertEqual(TubeMini.durationText(3725), "1:02:05")
        XCTAssertEqual(TubeMini.countText(1_234_567), "1,2 Tr")
        XCTAssertEqual(TubeMini.countText(35_000), "35 N")
        XCTAssertEqual(TubeMini.countText(999), "999")
        let now = Date()
        XCTAssertEqual(TubeMini.agoText(now.addingTimeInterval(-3 * 86_400), now: now), "3 ngày trước")
    }
}
