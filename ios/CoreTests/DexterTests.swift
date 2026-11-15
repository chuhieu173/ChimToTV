import XCTest

/// dexter.pw (11/2026): mẫu rút gọn từ phản hồi thật của API — cùng ca với DexterTest.kt.
final class DexterTests: XCTestCase {
    private let o = "https://dexter.pw"

    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
    }

    func testParsesHomeShelves() throws {
        let root = json(#"""
        {"id":"dexter","hero":[{"type":"tv","id":1405,"title":"Dexter","year":2006,"poster":"/i8OR.jpg","seasons":8,"playable":true},
                               {"type":"movie","id":354912,"title":"Coco","year":2017,"poster":"/6Ryi.jpg","playable":true}],
         "shelves":[
           {"id":"dexter-new","title":"Recently Added","items":[
              {"type":"movie","id":409502,"title":"I'm Not Ashamed","year":2016,"poster":"/a.jpg","playable":true},
              {"type":"movie","id":7,"title":"Chưa có video","year":2020,"playable":false}]},
           {"id":"dexter-film-series","title":"Film Series","kind":"collections","items":[]},
           {"id":"dexter-genre-878","title":"Science Fiction","items":[
              {"type":"movie","id":687163,"title":"Project Hail Mary","year":2026,"poster":"/c.jpg","playable":true}]},
           {"id":"dexter-other","title":"Something New","items":[{"type":"movie","id":5,"title":"X","poster":null}]}]}
        """#)
        let s = try Dexter.parseShelves(root, o)
        XCTAssertEqual(s.map(\.title), ["Nổi bật", "Phim mới thêm", "Khoa học viễn tưởng", "Something New"])
        XCTAssertEqual(s[0].films.map(\.url), ["\(o)/show/1405-dexter", "\(o)/movie/354912-coco"])
        XCTAssertEqual(s[0].films.map(\.badge), ["Phim bộ · 8 mùa", "2017"])
        XCTAssertEqual(s[0].films[1].poster, "https://image.tmdb.org/t/p/w342/6Ryi.jpg")
        XCTAssertEqual(s[1].films.map(\.url), ["\(o)/movie/409502-i-m-not-ashamed"]) // phim chưa phát được bị bỏ
        XCTAssertNil(s[3].films[0].poster)
    }

    func testParsesBrowseAndSearchPages() {
        let root = json(#"{"page":1,"totalPages":161,"results":[{"type":"movie","id":687163,"title":"Project Hail Mary","year":2026}]}"#)
        let url = "\(o)/api/browse?type=movie&genre=16&page=1&site=dexter"
        let p = Dexter.parseList(root, url)
        XCTAssertEqual(p.films.map(\.url), ["\(o)/movie/687163-project-hail-mary"])
        XCTAssertEqual(p.nextUrl, "\(o)/api/browse?type=movie&genre=16&page=2&site=dexter")
        XCTAssertNil(Dexter.parseList(json(#"{"page":3,"totalPages":3,"results":[{"type":"movie","id":1,"title":"A"}]}"#), url).nextUrl)
        XCTAssertTrue(Dexter.searchUrl(o, " frozen ii ").hasPrefix("\(o)/api/search?q=frozen"))
        let f = Dexter.filters(o)
        XCTAssertTrue(f.genres.contains { $0.title == "Hoạt hình" && $0.url == "\(o)/api/browse?type=movie&genre=16&page=1&site=dexter" })
        XCTAssertEqual(f.countries.first { $0.title == "Thập niên 1990" }?.url, "\(o)/api/browse?type=movie&decade=1990&page=1&site=dexter")
    }

    func testParsesMovieDetail() throws {
        let d = try Dexter.parseMovie(json(#"""
        {"type":"movie","id":354912,"title":"Coco","year":2017,"overview":"Miguel…","poster":"/6Ryi.jpg",
         "genres":["Family","Animation","Music"],"rating":8.2,"votes":21873,"runtime":105,"certification":"PG",
         "tagline":"The celebration of a lifetime.","playable":true}
        """#), o)
        XCTAssertEqual(d.url, "\(o)/movie/354912-coco")
        XCTAssertEqual(d.info, "2017  •  105 phút  •  PG  •  Gia đình, Hoạt hình, Âm nhạc  •  TMDB 8.2")
        XCTAssertEqual(d.poster, "https://image.tmdb.org/t/p/w500/6Ryi.jpg")
        XCTAssertEqual(d.groups.first?.episodes.map(\.url), ["\(o)/watch/354912-coco"])
        XCTAssertFalse(d.seasons)
    }

    func testParsesShowSeasons() throws {
        let show = json(#"""
        {"type":"tv","id":1405,"title":"Dexter","year":2006,"endYear":2013,"seasons":8,"episodeCount":96,"status":"Ended",
         "genres":["Crime","Drama"],"rating":8.2,"votes":6028,"poster":"/i8OR.jpg"}
        """#)
        let s1 = json(#"""
        {"number":1,"episodes":[{"season":1,"episode":1,"title":"Dexter","playable":true},
          {"season":1,"episode":2,"title":"Episode 2","playable":true},{"season":1,"episode":3,"title":"Popping Cherry","playable":false}]}
        """#)
        let s0 = json(#"{"number":0,"episodes":[{"season":0,"episode":1,"title":"Early Cuts","playable":true}]}"#)
        let d = try Dexter.parseShow(show, [(1, s1), (0, s0)], o)
        XCTAssertEqual(d.groups.map(\.name), ["Mùa 1", "Tập đặc biệt"])
        XCTAssertEqual(d.groups[0].episodes.map(\.title), ["Tập 1 · Dexter", "Tập 2"])
        XCTAssertEqual(d.groups[0].episodes[1].url, "\(o)/watch/show/1405-dexter/1/2")
        XCTAssertEqual(d.info, "2006–2013  •  8 mùa  •  96 tập  •  Đã kết thúc  •  Hình sự, Chính kịch  •  TMDB 8.2")
        // Phim chia mùa: tổng số tập, tập mới nhất = tập cuối của mùa cuối (không tính nhóm tập đặc biệt)
        XCTAssertTrue(d.seasons)
        XCTAssertEqual(d.episodeCount, 3)
        XCTAssertEqual(d.latestEpisode?.url, "\(o)/watch/show/1405-dexter/1/2")
    }

    func testPicksVietnameseThenEnglishSubtitles() {
        let root = json(#"""
        {"files":[{"id":"os-1","lang":"en"},{"id":"os-2","lang":"vi"},{"id":"ss-3","lang":"vi"},{"id":"os-4","lang":"ar"},
                  {"id":"x 5","lang":"en","url":"/api/s/20/subs/5.vtt"}]}
        """#)
        let r = Dexter.subtitles(root, "\(o)/api/subs/file/movie/354912/")
        XCTAssertFalse(r.pending)
        XCTAssertEqual(r.subs.map(\.label), ["Tiếng Việt 1", "Tiếng Việt 2", "Tiếng Anh 1", "Tiếng Anh 2"])
        XCTAssertEqual(r.subs[0].url, "\(o)/api/subs/file/movie/354912/os-2.vtt")
        XCTAssertEqual(r.subs[3].url, "\(o)/api/s/20/subs/5.vtt")
        let later = Dexter.subtitles(json(#"{"files":[],"pending":true}"#), "\(o)/api/subs/file/tv/1405/1/1/")
        XCTAssertTrue(later.subs.isEmpty && later.pending)
    }

    func testParsesSourcesAsHlsServers() throws {
        let root = json(#"""
        {"sources":[
          {"id":"s20-tv-1405-1-1","kind":"hls","url":"/api/s/20/tv/1405/1/1","label":"Server 20","family":20},
          {"id":"s21-tv-1405-1-1","kind":"hls","url":"/api/s/21/tv/1405/1/1?v=3","label":"Server 21","family":21},
          {"id":"x","kind":"hls","url":"/api/s/9/tv/1405/1/1","label":"Server 9","family":9,"sealed":true},
          {"id":"e","kind":"embed","url":"https://example.com/embed/1","label":"Embed"}]}
        """#)
        let subs = [SubTrack(label: "Tiếng Việt", url: "\(o)/api/subs/file/tv/1405/1/1/os-2.vtt", lang: "vi")]
        let src = try Dexter.parseSource(root, "\(o)/watch/show/1405-dexter/1/1", subs, "\(o)/api/subs/list/tv/1405/1/1")
        XCTAssertEqual(src.servers.map(\.type), ["s20", "s21"])
        let v = try XCTUnwrap(src.links["s21"])
        XCTAssertEqual(v.url, "\(o)/api/s/21/tv/1405/1/1?v=3")
        XCTAssertTrue(v.hls)
        XCTAssertEqual(v.subs, subs)
        XCTAssertEqual(v.subsLater, "\(o)/api/subs/list/tv/1405/1/1")
        XCTAssertTrue(src.next)
    }

    func testMakesSiteLikeSlugs() {
        XCTAssertEqual(Dexter.slug("Spider-Man: Brand New Day"), "spider-man-brand-new-day")
        XCTAssertEqual(Dexter.slug("I'm Not Ashamed"), "i-m-not-ashamed")
        XCTAssertEqual(Dexter.slug("Amélie"), "amelie")
        XCTAssertEqual(Dexter.slug("!!!"), "phim")
        XCTAssertEqual(Site.displayName(Dexter.host), "Phim Âu Mỹ 4K (dexter.pw)")
    }
}
