import Foundation

/// dexter.pw («Stream», từ 1.19) — bản Android: Dexter.kt (giữ cùng tên hàm để sửa song song). Phim Âu Mỹ (khoảng 6 400
/// phim lẻ, nhiều phim 4K) và phim bộ; ứng dụng React có API JSON, mã phim là mã TMDB:
/// - /api/site/dexter?v=8: trang chủ (hero + shelves); /api/site/dexter/series: trang phim bộ (cùng dạng).
/// - /api/browse?type=movie&page=N&site=dexter[&genre=<mã TMDB>][&sort=added][&decade=1990]: 40 phim / trang.
/// - /api/search?q=…&type=all&page=1&site=dexter.
/// - /api/movie/<id>, /api/tv/<id>, /api/tv/<id>/season/<n>, /api/tv/<id>/episode/<mùa>/<tập> (?site=dexter).
/// - sources: [{kind:"hls", url:"/api/s/21/…", family:21}] → danh sách HLS chính (4K / 1080p / 720p, fMP4, đoạn đổi đuôi
///   ảnh); máy chủ 20 của phim bộ tách âm thanh ra luồng riêng → phát bằng bản hls.js đầy đủ (Video.hls).
/// - /api/subs/list/movie/<id> | /tv/<id>/<mùa>/<tập>: phụ đề OpenSubtitles + Subsource (phim bộ hay trả {pending:true} một
///   lúc); tệp: /api/subs/file/<…>/<mã tệp>.vtt (vài tệp 404 «No such subtitle» → trình phát thử tệp sau).
/// Địa chỉ trong app theo đường dẫn của trang: phim = /movie/<id>-<slug>, phim bộ = /show/<id>-<slug>, tập phim lẻ =
/// /watch/<id>-<slug>, tập phim bộ = /watch/show/<id>-<slug>/<mùa>/<tập>. Danh sách = địa chỉ API.
enum Dexter {
    static let host = "dexter.pw"
    private static let site = "dexter"
    private static let img = "https://image.tmdb.org/t/p/"

    /// Ngôn ngữ phụ đề rời cho chọn (người xem Việt): tiếng Việt trước, tiếng Anh sau.
    private static let subLangs: [(String, String)] = [("vi", "Tiếng Việt"), ("en", "Tiếng Anh")]
    private static let subMax = ["vi": 12, "en": 4]

    /// Thể loại TMDB (phim lẻ + phim bộ) → tên tiếng Việt.
    private static let genreVi: [Int: String] = [
        28: "Hành động", 12: "Phiêu lưu", 16: "Hoạt hình", 35: "Hài", 80: "Hình sự", 99: "Tài liệu", 18: "Chính kịch",
        10751: "Gia đình", 14: "Giả tưởng", 36: "Lịch sử", 27: "Kinh dị", 10402: "Âm nhạc", 9648: "Bí ẩn", 10749: "Lãng mạn",
        878: "Khoa học viễn tưởng", 10770: "Phim truyền hình", 53: "Gay cấn", 10752: "Chiến tranh", 37: "Miền Tây",
        10759: "Hành động & phiêu lưu", 10762: "Thiếu nhi", 10763: "Tin tức", 10764: "Truyền hình thực tế",
        10765: "Viễn tưởng & giả tưởng", 10766: "Phim dài tập", 10767: "Talk show", 10768: "Chiến tranh & chính trị",
    ]
    private static let genreNameVi: [String: Int] = [
        "Action": 28, "Adventure": 12, "Animation": 16, "Comedy": 35, "Crime": 80, "Documentary": 99, "Drama": 18,
        "Family": 10751, "Fantasy": 14, "History": 36, "Horror": 27, "Music": 10402, "Mystery": 9648, "Romance": 10749,
        "Science Fiction": 878, "TV Movie": 10770, "Thriller": 53, "War": 10752, "Western": 37, "Action & Adventure": 10759,
        "Kids": 10762, "News": 10763, "Reality": 10764, "Sci-Fi & Fantasy": 10765, "Soap": 10766, "Talk": 10767,
        "War & Politics": 10768,
    ]

    /// Thể loại cho mục «Thể loại…» (phim lẻ — browse chỉ lọc phim lẻ).
    private static let filterGenres = [28, 12, 16, 35, 80, 99, 18, 10751, 14, 36, 27, 10402, 9648, 10749, 878, 53, 10752, 37]

    /// Mục «Thập niên…» (thay cho «Quốc gia…» — trang không lọc theo nước).
    private static let decades = [2020, 2010, 2000, 1990, 1980, 1970, 1960, 1950]

    /// Tên khối trang chủ của trang (tiếng Anh) → tiếng Việt; khối thể loại đọc theo mã (dexter-genre-<mã>).
    private static let shelfVi = [
        "Recently Added": "Phim mới thêm", "Series": "Phim bộ", "Top Rated": "Điểm cao", "Classics": "Kinh điển",
        "Most Liked on Stream": "Được thích nhất", "Top 10 Films on Stream": "Top 10 phim lẻ",
    ]

    static func isSite(_ url: String) -> Bool { Site.hostOf(url) == host }

    // MARK: - Trang chủ / danh sách

    static func home(_ base: String) async throws -> Home {
        let o = ApiSite.origin(base)
        let sections = try parseShelves(try await getJSON(siteApi(o)), o)
        if sections.isEmpty { throw AppError("Không đọc được trang chủ của \(host)") }
        return Home(sections: sections, categories: menuOf(base), movedTo: nil)
    }

    private static func siteApi(_ o: String) -> String { "\(o)/api/site/\(site)?v=8" }
    private static func seriesApi(_ o: String) -> String { "\(o)/api/site/\(site)/series" }
    private static func browse(_ o: String, _ query: String, _ page: Int = 1) -> String {
        "\(o)/api/browse?type=movie" + (query.isEmpty ? "" : "&\(query)") + "&page=\(page)&site=\(site)"
    }

    /// Trang chủ / trang phim bộ: hero thành «Nổi bật», mỗi shelf một khối (shelf bộ sưu tập không có phim thì bỏ).
    static func parseShelves(_ root: [String: Any], _ o: String) throws -> [FilmSection] {
        var out: [FilmSection] = []
        let hero = films(J.arr(root, "hero"), o)
        if !hero.isEmpty { out.append(FilmSection(title: "Nổi bật", films: hero)) }
        for s in J.objects(J.arr(root, "shelves")) {
            let f = films(J.arr(s, "items"), o)
            if !f.isEmpty { out.append(FilmSection(title: shelfTitle(s), films: f)) }
        }
        return out
    }

    private static let genreShelfRx = Rx(#"genre-(\d+)$"#)

    private static func shelfTitle(_ s: [String: Any]) -> String {
        let title = J.str(s, "title")
        if let id = genreShelfRx.group(1, in: J.str(s, "id")).flatMap({ Int($0) }), let vi = genreVi[id] { return vi }
        return shelfVi[title] ?? title
    }

    static func menuOf(_ base: String) -> [Category] {
        let o = ApiSite.origin(base)
        return [
            Category(title: "Phim mới & nổi bật", url: browse(o, "")),
            Category(title: "Phim mới thêm", url: browse(o, "sort=added")),
            Category(title: "Phim bộ", url: seriesApi(o)),
            Category(title: "Hoạt hình", url: browse(o, "genre=16")),
            Category(title: "Gia đình", url: browse(o, "genre=10751")),
            Category(title: "Hành động", url: browse(o, "genre=28")),
            Category(title: "Khoa học viễn tưởng", url: browse(o, "genre=878")),
            Category(title: "Hài", url: browse(o, "genre=35")),
            Category(title: "Kinh dị", url: browse(o, "genre=27")),
        ]
    }

    /// Thể loại (phim lẻ) và thập niên.
    static func filters(_ base: String) -> (genres: [Category], countries: [Category]) {
        let o = ApiSite.origin(base)
        return (filterGenres.map { Category(title: genreVi[$0] ?? "\($0)", url: browse(o, "genre=\($0)")) },
                decades.map { Category(title: "Thập niên \($0)", url: browse(o, "decade=\($0)")) })
    }

    static func newestUrl(_ base: String) -> String { browse(ApiSite.origin(base), "sort=added") }

    static func searchUrl(_ base: String, _ query: String) -> String {
        "\(ApiSite.origin(base))/api/search?q=" + query.trimmed.formEncoded + "&type=all&page=1&site=\(site)"
    }

    static func list(_ url: String) async throws -> FilmPage {
        let root = try await getJSON(url)
        // Trang phim bộ: các khối như trang chủ
        if (URL(string: url)?.path ?? "").hasPrefix("/api/site/") {
            return FilmPage(films: [], nextUrl: nil, sections: try parseShelves(root, ApiSite.origin(url)))
        }
        return parseList(root, url)
    }

    /// {page, totalPages, results:[…]} (browse / search) → trang sau = page + 1.
    static func parseList(_ root: [String: Any], _ url: String) -> FilmPage {
        let films = films(J.arr(root, "results"), ApiSite.origin(url))
        let page = J.int(root, "page", 1)
        let next = (!films.isEmpty && page < J.int(root, "totalPages")) ? ApiSite.withPage(url, page + 1) : nil
        return FilmPage(films: films, nextUrl: next)
    }

    private static func films(_ a: [Any]?, _ o: String) -> [Film] { J.objects(a).compactMap { film($0, o) }.distinct { $0.url } }

    /// Thẻ phim: phim bộ ghi số mùa, phim lẻ ghi năm. Phim trang chưa phát được (playable=false) thì bỏ.
    private static func film(_ it: [String: Any], _ o: String) -> Film? {
        if it["playable"] != nil && !J.bool(it, "playable") { return nil }
        let id = J.int(it, "id")
        guard id > 0, let title = J.str(it, "title").nonEmpty else { return nil }
        let tv = J.str(it, "type") == "tv"
        let seasons = J.int(it, "seasons"), year = J.int(it, "year")
        let badge: String? = tv ? (seasons > 0 ? "Phim bộ · \(seasons) mùa" : "Phim bộ") : (year > 0 ? String(year) : nil)
        return Film(url: filmUrl(o, tv, id, title), title: title, poster: image(J.str(it, "poster"), "w342"), badge: badge)
    }

    static func filmUrl(_ o: String, _ tv: Bool, _ id: Int, _ title: String) -> String {
        "\(o)/\(tv ? "show" : "movie")/\(id)-\(slug(title))"
    }

    /// "I'm Not Ashamed" → "i-m-not-ashamed" (như đường dẫn của trang; trang chỉ đọc mã số đứng trước).
    static func slug(_ title: String) -> String {
        let plain = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "d").lowercased()
        var out = "", dash = false
        for c in plain.unicodeScalars {
            if ("a"..."z").contains(c) || ("0"..."9").contains(c) {
                out.unicodeScalars.append(c)
                dash = false
            } else if !dash && !out.isEmpty {
                out += "-"
                dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "phim" : out
    }

    // MARK: - Chi tiết phim

    private static let refRx = Rx(#"^/(?:watch/)?(show|movie)/(\d+)"#)
    private static let watchMovieRx = Rx(#"^/watch/(\d+)"#)
    private static let watchEpRx = Rx(#"^/watch/show/(\d+)[^/]*/(\d+)/(\d+)"#)

    /// Phim / phim bộ trong địa chỉ của app: (phim bộ?, mã TMDB).
    private static func ref(_ url: String) throws -> (tv: Bool, id: Int) {
        let p = URL(string: url)?.path ?? ""
        if let g = refRx.groups(in: p), g.count >= 3, let id = Int(g[2]) { return (g[1] == "show", id) }
        if let id = watchMovieRx.group(1, in: p).flatMap({ Int($0) }) { return (false, id) }
        throw AppError("Địa chỉ phim lạ: \(url)")
    }

    static func detail(_ url: String) async throws -> FilmDetail {
        let o = ApiSite.origin(url)
        let r = try ref(url)
        if !r.tv { return try parseMovie(try await getJSON("\(o)/api/movie/\(r.id)?site=\(site)"), o) }
        let show = try await getJSON("\(o)/api/tv/\(r.id)?site=\(site)")
        let seasons = J.objects(J.arr(show, "seasonList"))
            .filter { $0["playable"] == nil || J.bool($0, "playable") }
            .map { J.int($0, "number") }
            .sorted { ($0 == 0 ? 1 : 0, $0) < ($1 == 0 ? 1 : 0, $1) } // mùa đặc biệt (0) xuống cuối
        // Các mùa tải song song — phim bộ dài có hàng chục mùa
        var bodies: [Int: [String: Any]] = [:]
        await withTaskGroup(of: (Int, [String: Any]?).self) { group in
            for n in seasons {
                group.addTask { (n, try? await getJSON("\(o)/api/tv/\(r.id)/season/\(n)?site=\(site)")) }
            }
            for await (n, body) in group { if let body = body { bodies[n] = body } }
        }
        return try parseShow(show, seasons.compactMap { n in bodies[n].map { (n, $0) } }, o)
    }

    static func parseMovie(_ m: [String: Any], _ o: String) throws -> FilmDetail {
        let id = J.int(m, "id")
        guard id > 0 else { throw AppError("Không đọc được thông tin phim") }
        let title = J.str(m, "title")
        let year = J.int(m, "year"), runtime = J.int(m, "runtime")
        let info = [
            year > 0 ? String(year) : "", runtime > 0 ? "\(runtime) phút" : "", J.str(m, "certification"), genres(m), rating(m),
        ].filter { !$0.isEmpty }.joined(separator: "  •  ").nonEmpty
        let url = filmUrl(o, false, id, title)
        let playable = m["playable"] == nil || J.bool(m, "playable")
        let groups = playable ? [EpisodeGroup(name: "Phim", episodes: [Episode(title: "Xem phim", url: "\(o)/watch/\(id)-\(slug(title))")])] : []
        return FilmDetail(url: url, title: title.nonEmpty ?? url, otherTitle: J.str(m, "tagline").nonEmpty,
                          poster: image(J.str(m, "poster"), "w500"), description: J.str(m, "overview").nonEmpty, info: info, groups: groups)
    }

    private static let genericEpRx = Rx(#"(?i)^episode\s*\d+$"#)

    /// seasons: (số mùa, JSON của mùa) — mỗi mùa một nhóm tập («Mùa 1»…); tập trang chưa phát được thì bỏ.
    static func parseShow(_ show: [String: Any], _ seasons: [(Int, [String: Any])], _ o: String) throws -> FilmDetail {
        let id = J.int(show, "id")
        guard id > 0 else { throw AppError("Không đọc được thông tin phim") }
        let title = J.str(show, "title")
        let s = slug(title)
        let groups = seasons.compactMap { (n, body) -> EpisodeGroup? in
            let eps = J.objects(J.arr(body, "episodes")).compactMap { e -> Episode? in
                if e["playable"] != nil && !J.bool(e, "playable") { return nil }
                let ep = J.int(e, "episode")
                guard ep > 0 else { return nil }
                let name = J.str(e, "title").nonEmpty.flatMap { genericEpRx.matches($0) ? nil : $0 }
                return Episode(title: "Tập \(ep)" + (name.map { " · \($0)" } ?? ""), url: "\(o)/watch/show/\(id)-\(s)/\(n)/\(ep)")
            }
            return eps.isEmpty ? nil : EpisodeGroup(name: n == 0 ? FilmDetail.specials : "Mùa \(n)", episodes: eps)
        }
        var years: [String] = []
        for y in [J.int(show, "year"), J.int(show, "endYear")] where y > 0 && !years.contains(String(y)) { years.append(String(y)) }
        let n = J.int(show, "seasons"), count = J.int(show, "episodeCount")
        let status: String
        switch J.str(show, "status") {
        case "Ended": status = "Đã kết thúc"
        case "Returning Series": status = "Đang chiếu"
        default: status = ""
        }
        let info = [
            years.joined(separator: "–"), n > 0 ? "\(n) mùa" : "", count > 0 ? "\(count) tập" : "", J.str(show, "certification"),
            status, genres(show), rating(show),
        ].filter { !$0.isEmpty }.joined(separator: "  •  ").nonEmpty
        return FilmDetail(url: filmUrl(o, true, id, title), title: title.nonEmpty ?? "Phim bộ", otherTitle: J.str(show, "tagline").nonEmpty,
                          poster: image(J.str(show, "poster"), "w500"), description: J.str(show, "overview").nonEmpty, info: info,
                          groups: groups, seasons: true)
    }

    private static func genres(_ o: [String: Any]) -> String {
        ((o["genres"] as? [Any]) ?? []).compactMap { ($0 as? String)?.nonEmpty }
            .map { g in genreNameVi[g].flatMap { genreVi[$0] } ?? g }.joined(separator: ", ")
    }

    private static func rating(_ o: [String: Any]) -> String {
        guard let r = (o["rating"] as? NSNumber)?.doubleValue, r > 0, J.int(o, "votes") >= 20 else { return "" }
        return "TMDB " + String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), r)
    }

    // MARK: - Tập phim

    /// Server = mỗi nguồn HLS của trang (phim lẻ: «Server 21»; phim bộ: thêm «Server 20»). Kèm danh sách phụ đề tải song
    /// song (tiếng Việt trước); phim bộ hay trả «đang tìm» (pending) → trình phát hỏi lại sau (Video.subsLater).
    static func source(_ epUrl: String) async throws -> EpisodeSource {
        let o = ApiSite.origin(epUrl)
        let p = URL(string: epUrl)?.path ?? ""
        let key: String, api: String
        if let g = watchEpRx.groups(in: p), g.count >= 4 {
            key = "tv/\(g[1])/\(g[2])/\(g[3])"
            api = "\(o)/api/tv/\(g[1])/episode/\(g[2])/\(g[3])?site=\(site)"
        } else {
            let id = try ref(epUrl).id
            key = "movie/\(id)"
            api = "\(o)/api/movie/\(id)?site=\(site)"
        }
        let subsList = "\(o)/api/subs/list/\(key)"
        async let subs = try? withTimeout(8) { () async throws -> (subs: [SubTrack], pending: Bool) in
            subtitles(try await getJSON(subsList), "\(o)/api/subs/file/\(key)/")
        }
        let body = try await getJSON(api)
        let found: (subs: [SubTrack], pending: Bool) = (await subs) ?? ([], true)
        return try parseSource(body, epUrl, found.subs, found.pending ? subsList : nil)
    }

    /// sources của phim / tập → server + link (HLS, kèm phụ đề). Nguồn «sealed» (mã hoá riêng của trang) bỏ qua.
    static func parseSource(_ root: [String: Any], _ epUrl: String, _ subs: [SubTrack], _ subsLater: String?) throws -> EpisodeSource {
        let o = ApiSite.origin(epUrl)
        var links: [String: Video] = [:]
        var servers: [Server] = []
        for s in J.objects(J.arr(root, "sources")) {
            if J.str(s, "kind") != "hls" || J.bool(s, "sealed") { continue }
            guard let url = abs(o, J.str(s, "url")) else { continue }
            let family = J.int(s, "family")
            let type = family > 0 ? "s\(family)" : (J.str(s, "id").nonEmpty ?? "s\(servers.count + 1)")
            if links[type] != nil { continue }
            // Phụ đề riêng của nguồn (đã khớp thời gian với video) đứng trước phụ đề tìm theo tên phim
            let own = ownSubtitles(J.arr(s, "subtitles"), o)
            links[type] = Video(url: url, subtitle: nil, file: false, hls: true, subs: mergeSubs(own, subs), subsLater: subsLater)
            servers.append(Server(label: J.str(s, "label").nonEmpty ?? "Server \(servers.count + 1)", type: type))
        }
        if links.isEmpty { throw AppError("Phim này chưa có video trên \(host)") }
        return EpisodeSource(epUrl: epUrl, servers: servers, postId: "", ep: "", sv: "", playerUrl: nil, directEmbed: nil,
                             pageMode: false, links: links, next: true)
    }

    /// Hỏi lại danh sách phụ đề còn «đang tìm»: (phụ đề, còn đang tìm?).
    static func subtitlesFrom(_ listUrl: String) async throws -> (subs: [SubTrack], pending: Bool) {
        let key = listUrl.components(separatedBy: "/api/subs/list/").last ?? ""
        return subtitles(try await getJSON(listUrl), "\(ApiSite.origin(listUrl))/api/subs/file/\(key)/")
    }

    /// {files:[{id, lang, label, source, release, url?}], pending?} → tiếng Việt (tối đa 12) rồi tiếng Anh (tối đa 4), giữ thứ
    /// tự của trang (xếp theo độ phổ biến). fileBase: …/api/subs/file/movie/<id>/
    static func subtitles(_ root: [String: Any], _ fileBase: String) -> (subs: [SubTrack], pending: Bool) {
        let files = J.objects(J.arr(root, "files"))
        let o = ApiSite.origin(fileBase)
        var out: [SubTrack] = []
        for (lang, name) in subLangs {
            let mine = files.filter { let l = J.str($0, "lang").lowercased(); return l == lang || l.hasPrefix("\(lang)-") }
                .prefix(subMax[lang] ?? 4)
            for (i, f) in mine.enumerated() {
                let id = J.str(f, "id").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? ""
                let url = J.str(f, "url").nonEmpty.flatMap { abs(o, $0) } ?? (fileBase + id + ".vtt")
                out.append(SubTrack(label: mine.count > 1 ? "\(name) \(i + 1)" : name, url: url, lang: lang))
            }
        }
        return (out, files.isEmpty && J.bool(root, "pending"))
    }

    private static func ownSubtitles(_ a: [Any]?, _ o: String) -> [SubTrack] {
        J.objects(a).compactMap { s in
            let lang = J.str(s, "lang").lowercased().components(separatedBy: "-").first ?? ""
            guard let name = subLangs.first(where: { $0.0 == lang })?.1, let url = abs(o, J.str(s, "url")) else { return nil }
            return SubTrack(label: "\(name) (khớp video)", url: url, lang: lang)
        }
    }

    /// Phụ đề riêng của nguồn trước, mỗi ngôn ngữ vẫn theo thứ tự tiếng Việt → tiếng Anh.
    private static func mergeSubs(_ own: [SubTrack], _ found: [SubTrack]) -> [SubTrack] {
        if own.isEmpty { return found }
        return subLangs.flatMap { l in own.filter { $0.lang == l.0 } + found.filter { $0.lang == l.0 } }
    }

    // MARK: - Tiện ích

    private static func getJSON(_ url: String) async throws -> [String: Any] {
        let r = try await Http.get(url, headers: ["Accept": "application/json"])
        guard let o = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any] else { throw AppError("\(host) trả dữ liệu lạ") }
        if o.count == 1, let e = o["error"] as? String { throw AppError(e) }
        return o
    }

    private static func image(_ path: String, _ size: String) -> String? {
        if path.isEmpty { return nil }
        if path.hasPrefix("http") { return path }
        return img + size + (path.hasPrefix("/") ? path : "/\(path)")
    }

    private static func abs(_ o: String, _ ref: String) -> String? {
        if ref.isEmpty { return nil }
        if ref.hasPrefix("http") { return ref }
        return ref.hasPrefix("/") ? o + ref : nil
    }
}
