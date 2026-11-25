import Foundation

// TubeMini — xem YouTube qua máy chủ tubemini-server của anh (dự án E:\DEV_CODE\TubeMini: Rust + yt-dlp + Deno, chạy trong nhà).
// App chỉ là «app khách» theo đúng hợp đồng docs/API.md của dự án đó: danh sách video là feed Atom kiểu GData (tìm kiếm, phổ biến,
// liên quan, video của kênh), các tính năng riêng ở /tm/v1 (link phát, kênh theo dõi, feed, lịch sử kèm chỗ xem). Video không đi qua
// máy chủ: máy chủ trả playlist HLS đã lọc (tiếng gốc, bỏ lồng tiếng AI), đoạn video tải thẳng từ googlevideo.
//
// Phát bằng chính trình phát phim (PlayerModel): danh sách video đang xem = các «tập» của một phim giả (tubemini://list/…), mỗi
// video = tubemini://video/<id>, các mức chất lượng = «server» (1080p / 720p / 360p / Chỉ nghe) → có sẵn thanh nút, tua, video kế,
// giới hạn giờ xem, màn xe CarPlay. Luôn phát bằng AVPlayer (NativeFilm). Theo dõi kênh và lịch sử nằm trên máy chủ (dùng chung với
// app TubeMini, không chia theo người xem — anh chọn 25/11/2026), không ghi vào lịch sử phim của Côn Bằng.

struct TubeVideo: Identifiable, Hashable {
    let id: String
    var title: String
    var author: String = ""
    var authorId: String = ""
    var duration = 0
    var views: Int?
    var published: Date?
    /// Chỗ đang xem (giây) — có ở danh sách Lịch sử
    var position: Int?

    var thumb: String { "https://i.ytimg.com/vi/\(id)/mqdefault.jpg" }
}

struct TubeChannel: Identifiable, Hashable {
    let id: String
    var name: String
    var avatar: String?
    var subscribers: Int?
}

struct TubePage {
    var videos: [TubeVideo] = []
    var channels: [TubeChannel] = []
    /// Link trang sau (rel='next' của feed) — gọi lại nguyên link.
    var next: String?
}

struct TubeStreams {
    struct Item {
        let quality: Int
        let kind: String
        let url: String
    }

    var items: [Item] = []
    var audio: String?
    var availableIn = 0

    /// Mục có chất lượng lớn nhất không vượt `max`; không có thì mục nhỏ nhất (như app TubeMini).
    func best(_ max: Int) -> Item? {
        items.filter { $0.quality <= max }.max { $0.quality < $1.quality } ?? items.min { $0.quality < $1.quality }
    }
}

enum TubeMini {
    // MARK: Cài đặt (dùng chung cả máy — máy chủ không chia theo người xem)

    /// Địa chỉ máy chủ, dạng http://máy:8080 (rỗng = chưa cài).
    static var server: String {
        get { Prefs.store.string(forKey: "tube_server") ?? "" }
        set { Prefs.store.set(normalize(newValue), forKey: "tube_server") }
    }

    /// Mã X-Auth-Token (auth_token trong config.toml của máy chủ; rỗng = máy chủ không bật).
    static var token: String {
        get { Prefs.store.string(forKey: "tube_token") ?? "" }
        set { Prefs.store.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "tube_token") }
    }

    static var configured: Bool { !server.isEmpty }

    /// «máy:8080», «http://máy:8080/» → «http://máy:8080».
    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        if t.isEmpty { return "" }
        if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") { t = "http://" + t }
        return t
    }

    // MARK: Địa chỉ trong app

    static let scheme = "tubemini://"
    static func isTubeUrl(_ u: String) -> Bool { u.hasPrefix(scheme) }
    static func videoUrl(_ id: String) -> String { "\(scheme)video/\(id)" }
    static func videoId(_ u: String) -> String? {
        let p = "\(scheme)video/"
        guard u.hasPrefix(p) else { return nil }
        let id = String(u.dropFirst(p.count))
        return id.isEmpty ? nil : id
    }

    // MARK: Video đã gặp (tên, kênh — gửi kèm lịch sử) và danh sách đang phát

    private static let lock = NSLock()
    private static var known: [String: TubeVideo] = [:]
    private static var queues: [String: FilmDetail] = [:]
    private static var queueOrder: [String] = []
    private static var positions: [String: Int] = [:]
    private static var freshIds = Set<String>()
    private static var lastReport: [String: Date] = [:]
    /// Chất lượng chọn một lần (vd «Chỉ nghe» từ menu ô video) — dùng cho lần mở tới.
    private static var oneShot: String?

    static func remember(_ vs: [TubeVideo]) {
        lock.lock()
        for v in vs { known[v.id] = v }
        if known.count > 3000 { known.removeAll() }
        lock.unlock()
    }

    static func info(_ id: String) -> TubeVideo? {
        lock.lock()
        defer { lock.unlock() }
        return known[id]
    }

    /// Dựng «phim giả» cho trình phát: danh sách video = các tập (video kế / trước, tự sang video sau khi hết).
    static func makeQueue(title: String, videos: [TubeVideo], audioOnly: Bool = false) -> String {
        remember(videos)
        let url = "\(scheme)list/\(UUID().uuidString)"
        let eps = videos.map { Episode(title: $0.title, url: videoUrl($0.id)) }
        let d = FilmDetail(url: url, title: title, otherTitle: nil, poster: videos.first?.thumb, description: nil, info: nil,
                           groups: [EpisodeGroup(name: "TubeMini", episodes: eps)])
        lock.lock()
        queues[url] = d
        queueOrder.append(url)
        if queueOrder.count > 20 { queues[queueOrder.removeFirst()] = nil }
        if audioOnly { oneShot = "tmaudio" }
        lock.unlock()
        return url
    }

    /// Site.detail(tubemini://…): danh sách đã dựng, hoặc một video lẻ.
    static func detail(_ url: String) async throws -> FilmDetail {
        lock.lock()
        let q = queues[url]
        lock.unlock()
        if let q = q { return q }
        guard let id = videoId(url) else { throw AppError("Danh sách TubeMini đã hết hạn — mở lại từ mục TubeMini.") }
        let v = info(id) ?? TubeVideo(id: id, title: "Video YouTube")
        return FilmDetail(url: url, title: v.title, otherTitle: nil, poster: v.thumb, description: nil, info: nil,
                          groups: [EpisodeGroup(name: "TubeMini", episodes: [Episode(title: v.title, url: url)])])
    }

    // MARK: Trình phát: chất lượng = server

    static let qualities = [
        Server(label: "720p", type: "tm720"), Server(label: "1080p", type: "tm1080"),
        Server(label: "360p", type: "tm360"), Server(label: "Chỉ nghe (tiếng)", type: "tmaudio"),
    ]

    /// KkPhim.source(tubemini://video/…): các mức chất lượng + chỗ xem dở trên máy chủ.
    static func source(_ ep: Episode) async throws -> EpisodeSource {
        var order = qualities
        lock.lock()
        let one = oneShot
        oneShot = nil
        lock.unlock()
        if let o = one, let i = order.firstIndex(where: { $0.type == o }) { order.insert(order.remove(at: i), at: 0) }
        if let id = videoId(ep.url), let h = try? await position(id) {
            lock.lock()
            positions[ep.url] = h.duration > 0 && (h.position < 10 || h.position >= h.duration - 20) ? 0 : h.position
            lock.unlock()
        }
        return EpisodeSource(epUrl: ep.url, servers: order, postId: "", ep: "", sv: "", playerUrl: nil, directEmbed: nil,
                             pageMode: false)
    }

    /// Chỗ xem dở của video (đọc ở source()) — PlayerModel dùng thay cho chỗ xem lưu trong máy.
    static func resume(_ epUrl: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return positions[epUrl] ?? 0
    }

    /// «Tải lại» trong trình phát: lần xin link tới bỏ bộ nhớ đệm của máy chủ (link hết hạn / 403).
    static func markFresh(_ epUrl: String) {
        guard let id = videoId(epUrl) else { return }
        lock.lock()
        freshIds.insert(id)
        lock.unlock()
    }

    /// Site.video: link phát theo mức chất lượng; video có quảng cáo đầu thì chờ YouTube mở link (available_in).
    static func video(_ epUrl: String, _ server: Server?) async throws -> Video {
        guard let id = videoId(epUrl) else { throw AppError("Video TubeMini không hợp lệ") }
        lock.lock()
        let fresh = freshIds.remove(id) != nil
        lock.unlock()
        let st = try await streams(id, fresh: fresh)
        if st.availableIn > 0 {
            Log.d("TubeMini", "\(id): chờ quảng cáo đầu \(st.availableIn) s")
            try await Task.sleep(nanoseconds: UInt64(min(30, st.availableIn)) * 1_000_000_000)
        }
        let type = server?.type ?? "tm720"
        if type == "tmaudio" {
            guard let a = st.audio else { throw AppError("Video này không có luồng chỉ tiếng — chọn chất lượng khác trong Menu.") }
            var v = Video(url: a)
            v.avPlayer = true
            return v
        }
        let want = type == "tm1080" ? 1080 : type == "tm360" ? 360 : 720
        guard let item = st.best(want) else { throw AppError("Máy chủ TubeMini không có link phát cho video này.") }
        var v = Video(url: item.url, file: item.kind == "mp4")
        v.avPlayer = true
        return v
    }

    // MARK: API của máy chủ

    private static func headers() -> [String: String] {
        let t = token
        return t.isEmpty ? [:] : ["X-Auth-Token": t]
    }

    private static func url(_ path: String) throws -> String {
        guard configured else { throw AppError("Chưa nhập địa chỉ máy chủ TubeMini.") }
        return path.hasPrefix("http") ? path : server + path
    }

    private static func get(_ path: String) async throws -> Data {
        do {
            return try await Http.get(try url(path), headers: headers()).data
        } catch let e as Http.HttpError {
            throw AppError(message(e.code))
        }
    }

    private static func message(_ code: Int) -> String {
        switch code {
        case 401: return "Máy chủ TubeMini cần mã (token) — nhập ở Cài đặt máy chủ."
        case 404: return "Máy chủ TubeMini không có mục này (máy chủ cũ quá?)."
        case 502: return "YouTube không trả lời hoặc không lấy được link (máy chủ TubeMini báo lỗi 502)."
        default: return "Máy chủ TubeMini trả về lỗi HTTP \(code)."
        }
    }

    private static func q(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?"))) ?? s }

    /// Kiểm tra kết nối: «máy chủ 0.6.0 · yt-dlp 2026.10.26».
    static func ping() async throws -> String {
        let a = TubeXML.attrs(try await get("/tm/v1/ping"), "tm:ping")
        var parts = ["máy chủ \(a["server"] ?? "?")"]
        if let y = a["yt_dlp"], !y.isEmpty { parts.append("yt-dlp \(y)") } else { parts.append("THIẾU yt-dlp") }
        if (a["deno"] ?? "").isEmpty { parts.append("THIẾU Deno") }
        return parts.joined(separator: " · ")
    }

    /// Phổ biến: "" = trộn, "Music" / "News" / "Sports" / "Games" / "Film" = từng chủ đề.
    static func popular(_ cat: String) async throws -> TubePage {
        let feed = cat.isEmpty ? "most_popular" : "most_popular_\(cat)"
        return try await page("/feeds/api/standardfeeds/\(feed)?max-results=50")
    }

    static func search(_ text: String) async throws -> TubePage {
        try await page("/feeds/api/videos?q=\(q(text))&max-results=25")
    }

    static func searchChannels(_ text: String) async throws -> [TubeChannel] {
        try await page("/feeds/api/channels?q=\(q(text))&max-results=25").channels
    }

    static func related(_ id: String) async throws -> TubePage { try await page("/feeds/api/videos/\(id)/related?max-results=25") }
    static func uploads(_ channel: String) async throws -> TubePage { try await page("/feeds/api/users/\(channel)/uploads?max-results=25") }
    static func feed(fresh: Bool) async throws -> TubePage { try await page("/tm/v1/feed?max-results=25" + (fresh ? "&fresh=1" : "")) }
    static func history() async throws -> TubePage { try await page("/tm/v1/history?max-results=25") }
    static func subscriptions() async throws -> [TubeChannel] { try await page("/tm/v1/subscriptions").channels }

    /// Trang sau / trang bất kỳ (link next của feed là địa chỉ đầy đủ).
    static func page(_ path: String) async throws -> TubePage {
        let p = TubeXML.feed(try await get(path))
        remember(p.videos)
        return p
    }

    static func subscribe(_ channel: String) async throws {
        do {
            _ = try await Http.post(try url("/tm/v1/subscriptions"), form: ["channel_id": channel], headers: headers())
        } catch let e as Http.HttpError {
            throw AppError(message(e.code))
        }
    }

    static func unsubscribe(_ channel: String) async throws { try await delete("/tm/v1/subscriptions/\(channel)") }
    static func deleteHistory(_ id: String) async throws { try await delete("/tm/v1/history/\(id)") }

    private static func delete(_ path: String) async throws {
        var r = try Http.request(try url(path), headers: headers())
        r.httpMethod = "DELETE"
        let (_, resp) = try await Http.session.data(for: r)
        if let c = (resp as? HTTPURLResponse)?.statusCode, c >= 400 { throw AppError(message(c)) }
    }

    static func position(_ id: String) async throws -> (position: Int, duration: Int) {
        let a = TubeXML.attrs(try await get("/tm/v1/history/\(id)"), "tm:history")
        return (Int(a["position"] ?? "") ?? 0, Int(a["duration"] ?? "") ?? 0)
    }

    static func streams(_ id: String, fresh: Bool) async throws -> TubeStreams {
        TubeXML.streams(try await get("/tm/v1/videos/\(id)/streams" + (fresh ? "?fresh=1" : "")))
    }

    /// Lưu chỗ đang xem lên máy chủ (app TubeMini gửi ~15 giây một lần và khi đóng trình phát). `force`: gửi ngay.
    static func report(_ epUrl: String, position: Int, duration: Int, force: Bool) {
        guard configured, let id = videoId(epUrl) else { return }
        let now = Date()
        lock.lock()
        if !force, let last = lastReport[id], now.timeIntervalSince(last) < 15 {
            lock.unlock()
            return
        }
        lastReport[id] = now
        positions[epUrl] = position
        let v = known[id]
        lock.unlock()
        var form = ["video_id": id, "position": String(max(0, position))]
        if duration > 0 { form["duration"] = String(duration) }
        if let v = v {
            form["title"] = v.title
            if !v.author.isEmpty { form["author"] = v.author }
            if !v.authorId.isEmpty { form["author_id"] = v.authorId }
        }
        let target = server + "/tm/v1/history"
        let h = headers()
        let body = form
        Task.detached {
            do { _ = try await Http.post(target, form: body, headers: h) } catch {
                Log.d("TubeMini", "không lưu được chỗ xem \(id): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Hiện số liệu

    static func durationText(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 1.234.567 → «1,2 Tr»; 35.000 → «35 N».
    static func countText(_ n: Int) -> String {
        func one(_ x: Double) -> String {
            let r = (x * 10).rounded() / 10
            return (r.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(r)) : String(r)).replacingOccurrences(of: ".", with: ",")
        }
        if n >= 1_000_000_000 { return one(Double(n) / 1e9) + " T" }
        if n >= 1_000_000 { return one(Double(n) / 1e6) + " Tr" }
        if n >= 1_000 { return one(Double(n) / 1e3) + " N" }
        return String(n)
    }

    static func agoText(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 3600 { return "\(max(1, Int(s / 60))) phút trước" }
        if s < 86_400 { return "\(Int(s / 3600)) giờ trước" }
        if s < 86_400 * 30 { return "\(Int(s / 86_400)) ngày trước" }
        if s < 86_400 * 365 { return "\(Int(s / (86_400 * 30))) tháng trước" }
        return "\(Int(s / (86_400 * 365))) năm trước"
    }

    /// «kênh · 1,2 Tr lượt xem · 3 ngày trước»
    static func metaText(_ v: TubeVideo) -> String {
        var parts: [String] = []
        if !v.author.isEmpty { parts.append(v.author) }
        if let n = v.views, n > 0 { parts.append("\(countText(n)) lượt xem") } // video vừa đăng: feed ghi 0
        if let p = v.published, p.timeIntervalSince1970 > 86_400 { parts.append(agoText(p)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Đọc XML của máy chủ (Atom kiểu GData + phần tử tm:)

enum TubeXML {
    /// Thuộc tính của phần tử `name` đầu tiên (tm:ping, tm:history…); gặp tm:error thì trả thuộc tính của nó.
    static func attrs(_ data: Data, _ name: String) -> [String: String] {
        let p = Reader(want: [name, "tm:error"])
        p.run(data)
        return p.found[name] ?? p.found["tm:error"] ?? [:]
    }

    static func streams(_ data: Data) -> TubeStreams {
        let r = StreamsReader()
        r.run(data)
        return r.out
    }

    static func feed(_ data: Data) -> TubePage {
        let r = FeedReader()
        r.run(data)
        return r.page
    }

    class Base: NSObject, XMLParserDelegate {
        func run(_ data: Data) {
            let x = XMLParser(data: data)
            x.shouldProcessNamespaces = false
            x.delegate = self
            x.parse()
        }
    }

    final class Reader: Base {
        let want: Set<String>
        var found: [String: [String: String]] = [:]
        init(want: [String]) { self.want = Set(want) }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if want.contains(name) && found[name] == nil { found[name] = attributes }
        }
    }

    final class StreamsReader: Base {
        var out = TubeStreams()
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            switch name {
            case "tm:streams": out.availableIn = Int(a["available_in"] ?? "") ?? 0
            case "tm:stream":
                if let u = a["url"], let q = Int(a["quality"] ?? "") {
                    out.items.append(.init(quality: q, kind: a["kind"] ?? "hls", url: u))
                }
            case "tm:audio": out.audio = a["url"]
            default: break
            }
        }
    }

    final class FeedReader: Base {
        var page = TubePage()
        private var inEntry = false
        private var inAuthor = false
        private var text = ""
        private var e: [String: String] = [:]
        private var thumbs: [String: String] = [:]
        private static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            text = ""
            switch name {
            case "entry":
                inEntry = true
                e = [:]
                thumbs = [:]
            case "author": inAuthor = true
            case "link":
                if !inEntry, a["rel"] == "next", let h = a["href"] { page.next = h }
            case "media:thumbnail":
                if let u = a["url"] { thumbs[a["yt:name"] ?? "default"] = u }
            case "yt:duration": e["duration"] = a["seconds"]
            case "yt:statistics": e["views"] = a["viewCount"]
            case "yt:channelStatistics": e["subs"] = a["subscriberCount"]
            case "tm:position": e["position"] = a["seconds"]
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { text = "" }
            guard inEntry else { return }
            switch name {
            case "author": inAuthor = false
            case "name": if inAuthor { e["author"] = t }
            case "yt:userId": if inAuthor { e["authorId"] = t }
            case "yt:uploaderId": if e["authorId"] == nil { e["authorId"] = t }
            case "title": if e["title"] == nil { e["title"] = t }
            case "yt:videoid": e["videoid"] = t
            case "yt:channelId": e["channel"] = t
            case "id": e["id"] = t
            case "published": e["published"] = t
            case "entry":
                inEntry = false
                finish()
            default: break
            }
        }

        private func finish() {
            let tagId = e["id"] ?? ""
            let vid = e["videoid"] ?? (tagId.contains(":video:") ? String(tagId.split(separator: ":").last ?? "") : nil)
            if let v = vid, !v.isEmpty {
                var x = TubeVideo(id: v, title: e["title"] ?? "")
                x.author = e["author"] ?? ""
                x.authorId = e["authorId"] ?? ""
                x.duration = Int(e["duration"] ?? "") ?? 0
                x.views = Int(e["views"] ?? "")
                x.published = e["published"].flatMap { Self.iso.date(from: $0) }
                x.position = Int(e["position"] ?? "")
                page.videos.append(x)
                return
            }
            let ch = e["channel"] ?? (tagId.contains(":channel:") ? String(tagId.split(separator: ":").last ?? "") : nil)
            if let c = ch, !c.isEmpty {
                page.channels.append(TubeChannel(id: c, name: e["title"] ?? e["author"] ?? "",
                                                 avatar: thumbs["default"] ?? thumbs.values.first, subscribers: Int(e["subs"] ?? "")))
            }
        }
    }
}
