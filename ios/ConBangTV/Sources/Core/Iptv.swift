import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Compression)
import Compression
#endif

// Truyền hình (IPTV) — danh sách kênh M3U / M3U8 người xem tự thêm (app không kèm sẵn kênh), lịch phát sóng XMLTV, đài radio,
// danh sách thể thao theo giờ trận. Bản iPad / iPhone / Mac của lõi Rust (linux/core/src/iptv.rs — Windows, Linux) và bản tivi
// (Iptv.kt): cùng khoá cài đặt, cùng cách tính.
//
// - Danh sách lưu nguyên tệp ở Application Support/iptv/<mã>.m3u (thêm từ tệp: iptv/files/<mã>.m3u), đọc vào RAM khi cần; tải lại
//   khi cũ quá 6 giờ (có trận: 30 phút; trận sắp / đang đá chưa có link thật: 5 phút); tệp tải về y như lần trước thì khỏi đọc lại.
// - Lịch XMLTV (.xml / .gz) đọc dần, chỉ giữ chương trình của kênh trong danh sách, từ 24 giờ trước tới 48 giờ sau;
//   lưu iptv/epg-<mã>.json.
// - Khoá cài đặt: iptv_lists, iptv_active, iptv_epg_url, iptv_bad, iptv_hide_bad, iptv_auto_source, iptv_reminders (cả nhà),
//   iptv_favs, iptv_recent (từng người xem).

/// Kênh: `urls` = các nguồn (HLS trước FLV, link giả cuối); `hdr` = Referer / UA riêng của nguồn gộp vào từ dòng khác.
struct IptvChannel {
    var k: String
    var n: String
    var g: Int
    var num: String
    var logo: String?
    var tid: String?
    var urls: [String]
    var referer: String?
    var ua: String?
    var hdr: [(url: String, referer: String, ua: String)]
    var kick: Double
    var dur: Int
    var radio: Bool
    var vod: Bool
    var kids: Bool

    var nolink: Bool { urls.allSatisfy { IptvParse.isPlaceholder($0) } }

    /// Referer / User-Agent gửi lên máy chủ cho nguồn `url`.
    func headers(for url: String) -> (referer: String?, ua: String?) {
        if let h = hdr.first(where: { $0.url == url }) {
            return (h.referer.isEmpty ? nil : h.referer, h.ua.isEmpty ? nil : h.ua)
        }
        return (referer, ua)
    }

    var guideKeys: [String] { (tid.map { [$0] } ?? []) + ["n:\(k)"] }
}

/// Danh sách đã đọc.
final class IptvLoaded {
    let listId: String
    let channels: [IptvChannel]
    let groups: [String]
    let hasMatches: Bool
    let epg: String?
    let entries: Int
    let sawExtinf: Bool
    private let keyIndex: [String: Int]

    init(listId: String, channels: [IptvChannel], groups: [String], hasMatches: Bool, epg: String?, entries: Int, sawExtinf: Bool) {
        self.listId = listId
        self.channels = channels
        self.groups = groups
        self.hasMatches = hasMatches
        self.epg = epg
        self.entries = entries
        self.sawExtinf = sawExtinf
        var ix: [String: Int] = [:]
        ix.reserveCapacity(channels.count)
        for (i, c) in channels.enumerated() where ix[c.k] == nil { ix[c.k] = i }
        keyIndex = ix
    }

    func byKey(_ k: String) -> (Int, IptvChannel)? { keyIndex[k].map { ($0, channels[$0]) } }

    /// Đọc danh sách M3U (luồng dòng) thành kênh: trùng tên (chuẩn hoá) trong cùng nhóm gộp thành nhiều nguồn; kênh thể thao ghi
    /// giờ trận trong tên thì tách giờ ra, mỗi BLV một kênh.
    static func build(listId: String, lines: IptvLines, now: Double) -> IptvLoaded {
        let r = IptvReader()
        var channels: [IptvChannel] = []
        var groups: [String] = []
        var groupIx: [String: (id: Int, norm: String, kids: Bool)] = [:]
        var merge: [String: Int] = [:]
        var hasMatches = false
        var entries = 0
        while let line = lines.nextLine() {
            guard let e = r.line(line) else { continue }
            entries += 1
            var n = e.name
            var k: String
            var minutes = 0
            var kickAt = 0.0
            if let kk = IptvParse.kickoff(n, now: now), IptvParse.isMatchName(e.name) {
                hasMatches = true
                minutes = IptvParse.matchMinutes(n)
                n = IptvParse.matchName(n, kk)
                kickAt = kk.at
                let plain = n.replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ")
                k = "\(IptvParse.norm(plain))@\(Int((kk.at / 60).rounded(.down)))"
            } else {
                n = IptvParse.displayName(n)
                let x = IptvParse.norm(n)
                k = x.isEmpty ? n.lowercased() : x
            }
            let gi: (id: Int, norm: String, kids: Bool)
            if let x = groupIx[e.group] {
                gi = x
            } else {
                groups.append(e.group)
                let gn = IptvParse.norm(e.group)
                gi = (groups.count - 1, gn, IptvParse.kidsWords.contains { gn.contains($0) })
                groupIx[e.group] = gi
            }
            let mk = "\(gi.id)|\(k)"
            if let ix = merge[mk] {
                var c = channels[ix]
                if c.urls.contains(e.url) { continue }
                let rank = IptvParse.sourceRank(e.url)
                let at = c.urls.firstIndex { IptvParse.sourceRank($0) > rank } ?? c.urls.count
                c.urls.insert(e.url, at: at)
                if (e.referer ?? "") != (c.referer ?? "") || (e.ua ?? "") != (c.ua ?? "") {
                    c.hdr.append((e.url, e.referer ?? "", e.ua ?? ""))
                }
                channels[ix] = c
                continue
            }
            let path = IptvParse.pathOf(e.url)
            let ext = IptvParse.extOfPath(path)
            let chno = e.attrs["tvg-chno"] ?? ""
            let ch = IptvChannel(
                k: k, n: n, g: gi.id, num: chno.isEmpty ? String(entries) : chno,
                logo: e.attrs["tvg-logo"].flatMap { $0.hasPrefix("http") ? $0 : nil },
                tid: e.attrs["tvg-id"].flatMap { $0.isEmpty ? nil : $0 },
                urls: [e.url], referer: (e.referer?.isEmpty == false) ? e.referer : nil, ua: (e.ua?.isEmpty == false) ? e.ua : nil,
                hdr: [], kick: kickAt, dur: minutes,
                radio: IptvParse.isRadio(e.attrs, groupNorm: gi.norm, ext: ext), vod: IptvParse.isVodPath(path),
                kids: gi.kids || IptvParse.isKids(groupNorm: "", key: k))
            merge[mk] = channels.count
            channels.append(ch)
        }
        return IptvLoaded(listId: listId, channels: channels, groups: groups, hasMatches: hasMatches, epg: r.epg, entries: entries,
                          sawExtinf: r.sawExtinf)
    }
}

/// Danh sách kênh người xem đã thêm (địa chỉ hoặc tệp).
struct IptvList: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var url: String?
    var file: String?
    var src: String?
    var count: Int = 0
    var updated: Int64 = 0
    var epg: String?
    var err: String?
    var sig: String?
}

/// Lịch phát sóng đã đọc của một danh sách.
struct IptvGuide: Codable {
    var list: String
    var src: String
    var fetched: Int64
    var prog: [String: [IptvProgramme]]

    func programmes(_ c: IptvChannel) -> [IptvProgramme] {
        for k in c.guideKeys {
            if let p = prog[k], !p.isEmpty { return p }
        }
        return []
    }
}

/// Bộ lọc của lưới / bảng kênh: nhóm (số thứ tự trong danh sách; nil = tất cả), chỉ yêu thích, chữ tìm (tên hoặc số kênh).
struct IptvFilter: Hashable {
    var group: Int?
    var favs = false
    var q = ""
}

/// Một nguồn của kênh (trình phát).
struct IptvSource {
    let url: String
    let referer: String?
    let ua: String?
    let bad: String?
}

/// Một kênh cho giao diện (kèm chương trình đang phát / kế tiếp, trạng thái trận, dấu hỏng, yêu thích).
struct IptvChannelView: Identifiable {
    /// Số thứ tự trong danh sách đã đọc
    var id: Int
    /// Vị trí trong bộ lọc (trang / trình phát)
    var index = 0
    var total = 0
    var k: String
    var n: String
    var g: String
    var num: String
    var logo: String?
    var radio: Bool
    var vod: Bool
    var kick: Double
    var dur: Int
    var nolink: Bool
    var sources: Int
    var fav: Bool
    var match: IptvMatch
    var matchLine: String?
    var bad: String?
    var now: IptvProgramme?
    var next: IptvProgramme?
    var programmes: [IptvProgramme] = []
    var urls: [IptvSource] = []
    var tid: String?
}

/// Một ô kênh của hàng Truyền hình trên trang chủ (Iptv.home).
struct IptvHomeItem: Hashable, Identifiable {
    /// Duy nhất trong hàng (vị trí) — không theo khoá kênh (một kênh có thể nằm ở nhiều nhóm)
    let id: String
    let k: String
    /// Danh sách của kênh (kênh vừa xem của danh sách khác: bấm thì đổi sang danh sách đó)
    let list: String?
    let n: String
    let logo: String?
    let radio: Bool
    /// Dòng 2: chương trình đang phát / giờ trận / tên nhóm
    let line: String
    /// Tiến độ 0…1 (chương trình đang phát / trận đang đá); -1 = không có
    let frac: Double
    /// Nhãn góc: ĐANG ĐÁ / SẮP ĐÁ / RADIO
    let tag: String?
    /// Nhãn đỏ (trận đang đá)
    let live: Bool
    /// Vị trí trong bộ lọc Yêu thích (hàng «Kênh yêu thích»: ↑↓ trong trình phát đi trong yêu thích); -1 = mở theo khoá
    let index: Int
}

/// Các hàng Truyền hình của trang chủ.
struct IptvHome: Equatable {
    var list: String? = nil
    var recent: [IptvHomeItem] = []
    var favs: [IptvHomeItem] = []
    var live: [IptvHomeItem] = []
    var radio: [IptvHomeItem] = []

    func items(_ row: String) -> [IptvHomeItem] {
        switch row {
        case "tv-recent": return recent
        case "tv-favs": return favs
        case "tv-live": return live
        case "tv-radio": return radio
        default: return []
        }
    }
}

/// Kênh vừa xem (mới nhất trước, tối đa 12).
struct IptvRecent: Codable, Equatable {
    var k: String
    var n: String
    var g: String
    var l: String?
    var logo: String?
    var radio: Bool?
}

/// Nhắc giờ phát («Nhắc tôi» 5 phút trước) / bóng lăn.
struct IptvReminder: Codable {
    var k: String
    var n: String
    var t: String
    var s: Double
    var at: Int64
    var kick: Bool
    var text: String?
}

/// Một nhóm kênh (số thứ tự trong danh sách, tên, số kênh đang hiện).
struct IptvGroup: Identifiable {
    let id: Int
    let name: String
    let count: Int
}

/// Nhóm có kênh + số kênh tất cả / yêu thích.
struct IptvGroups {
    var groups: [IptvGroup] = []
    var total = 0
    var favs = 0
    var list: String?
}

/// Trạng thái cho giao diện: đang tải / dòng trạng thái / lần đổi dữ liệu (giao diện hỏi lại khi khác).
struct IptvStatus {
    var loading: Bool
    var guideLoading: Bool
    var status: String?
    var version: UInt64
    var active: IptvList?
    var loaded: String?
}

enum Iptv {
    private static let listMaxAge: Int64 = 6 * 3600 * 1000
    private static let matchListMaxAge: Int64 = 30 * 60 * 1000
    private static let waitingListMaxAge: Int64 = 5 * 60 * 1000
    private static let autoRetryGap: Int64 = 3 * 60 * 1000
    private static let guideMaxAge: Int64 = 6 * 3600 * 1000
    /// Đổi cách đọc → dấu tệp cũ không khớp (đọc lại).
    private static let parseVersion = 3

    static func nowSec() -> Double { Date().timeIntervalSince1970 }

    // MARK: - Trạng thái (một khoá)

    private final class State {
        var loaded: IptvLoaded?
        var guide: IptvGuide?
        var loading = false
        var guideLoading = false
        var status: String?
        var lastTry: Int64 = 0
        var version: UInt64 = 0
        var filter: (key: String, version: UInt64, ids: [Int32])?
        var parsing: (id: String, task: Task<IptvLoaded?, Never>)?
    }

    private static let lock = NSLock()
    private static let st = State()

    private static func locked<T>(_ f: (State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f(st)
    }

    private static func changed() {
        locked {
            $0.version += 1
            $0.filter = nil
        }
    }

    private static func setStatus(_ s: String?) { locked { $0.status = s } }

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("iptv", isDirectory: true)
        try? FileManager.default.createDirectory(at: d.appendingPathComponent("files", isDirectory: true), withIntermediateDirectories: true)
        return d
    }

    private static func rawFile(_ l: IptvList) -> URL {
        if let f = l.file { return dir.appendingPathComponent("files").appendingPathComponent(f) }
        return dir.appendingPathComponent("\(l.id).m3u")
    }

    // MARK: - Danh sách

    static func lists() -> [IptvList] { Prefs.decode([IptvList].self, "iptv_lists") ?? [] }

    private static func saveLists(_ l: [IptvList]) { Prefs.encode(l, "iptv_lists") }

    private static func updateList(_ id: String, _ f: (inout IptvList) -> Void) {
        var l = lists()
        if let i = l.firstIndex(where: { $0.id == id }) { f(&l[i]) }
        saveLists(l)
    }

    static func activeList() -> IptvList? {
        let l = lists()
        let a = Prefs.store.string(forKey: "iptv_active")
        return l.first { $0.id == a } ?? l.first
    }

    static func setActive(_ id: String?) {
        Prefs.store.set(id, forKey: "iptv_active")
        locked {
            $0.loaded = nil
            $0.guide = nil
            $0.version += 1
            $0.filter = nil
        }
    }

    @discardableResult
    static func addList(_ input: String, name: String? = nil) -> IptvList {
        let url = IptvParse.listUrl(input)
        let nm = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let l = IptvList(id: "l\(nowMs())", name: nm.isEmpty ? IptvParse.nameFromUrl(url) : nm, url: url)
        saveLists(lists() + [l])
        setActive(l.id)
        return l
    }

    /// Thêm nhiều danh sách cùng lúc (địa chỉ tách bằng `IptvParse.splitUrls` — dán mỗi dòng một danh sách). Địa chỉ đã có thì bỏ
    /// qua (`existing`). Danh sách đầu tiên vừa thêm thành danh sách đang dùng (các danh sách khác tải khi được chọn). Tên: một
    /// danh sách thì dùng `name`; nhiều thì «name 1», «name 2»…; không có tên thì đặt theo địa chỉ.
    static func addLists(_ text: String, name: String? = nil) -> (added: [IptvList], existing: Int) {
        var all = lists()
        var existing = 0
        let fresh = IptvParse.splitUrls(text).filter { u in
            let k = IptvParse.listUrlKey(u)
            let dup = all.contains { $0.url.map(IptvParse.listUrlKey) == k }
            if dup { existing += 1 }
            return !dup
        }
        let nm = name?.trimmingCharacters(in: .whitespaces) ?? ""
        var stamp = nowMs()
        var added: [IptvList] = []
        for (i, url) in fresh.enumerated() {
            while all.contains(where: { $0.id == "l\(stamp)" }) { stamp += 1 } // mã riêng cho từng danh sách (cùng một mili-giây)
            let n = nm.isEmpty ? IptvParse.nameFromUrl(url) : fresh.count == 1 ? nm : "\(nm) \(i + 1)"
            let l = IptvList(id: "l\(stamp)", name: n, url: url)
            stamp += 1
            all.append(l)
            added.append(l)
        }
        if let first = added.first {
            saveLists(all)
            setActive(first.id)
        }
        return (added, existing)
    }

    /// Thêm danh sách từ tệp M3U trên máy (chọn trong Tệp / Finder): chép vào iptv/files/.
    static func addFile(_ src: URL, name: String? = nil) throws -> IptvList {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        guard let h = try? FileHandle(forReadingFrom: src) else { throw AppError("Không đọc được tệp.") }
        let head = h.readData(ofLength: 64 * 1024)
        try? h.close()
        if head.isEmpty { throw AppError("Tệp trống.") }
        let text = String(decoding: head, as: UTF8.self)
        if !text.contains("#EXTINF") && !text.contains("http") {
            throw AppError("Tệp không phải danh sách M3U (không có dòng #EXTINF / địa chỉ kênh nào).")
        }
        let id = "l\(nowMs())"
        let file = "\(id).m3u"
        let to = dir.appendingPathComponent("files").appendingPathComponent(file)
        do {
            try FileManager.default.copyItem(at: src, to: to)
        } catch {
            throw AppError("Không chép được tệp: \(error.localizedDescription)")
        }
        let nm = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let l = IptvList(id: id, name: nm.isEmpty ? IptvParse.nameFromFile(src.lastPathComponent) : nm, file: file,
                         src: src.lastPathComponent)
        saveLists(lists() + [l])
        setActive(id)
        Log.d("IPTV", "thêm danh sách từ tệp \(src.lastPathComponent) → \(id)")
        return l
    }

    static func renameList(_ id: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        updateList(id) { $0.name = String(n.prefix(40)) }
        changed()
    }

    static func removeList(_ id: String) {
        let all = lists()
        guard let l = all.first(where: { $0.id == id }) else { return }
        let rest = all.filter { $0.id != id }
        saveLists(rest)
        try? FileManager.default.removeItem(at: rawFile(l))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("epg-\(id).json"))
        let loadedId = locked { $0.loaded?.listId }
        if Prefs.store.string(forKey: "iptv_active") == id || activeList()?.id != loadedId {
            setActive(rest.first?.id)
        } else {
            changed()
        }
    }

    static func status() -> IptvStatus {
        let a = activeList()
        return locked { IptvStatus(loading: $0.loading, guideLoading: $0.guideLoading, status: $0.status, version: $0.version,
                                   active: a, loaded: $0.loaded?.listId) }
    }

    static var loading: Bool { locked { $0.loading || $0.guideLoading } }

    static var version: UInt64 { locked { $0.version } }

    // MARK: - Đọc / tải danh sách

    private static func parseFile(_ url: URL, id: String) -> IptvLoaded? {
        guard let plain = gunzipIfNeeded(url), let r = IptvByteReader(url: plain) else { return nil }
        defer { if plain != url { try? FileManager.default.removeItem(at: plain) } }
        return IptvLoaded.build(listId: id, lines: r, now: nowSec())
    }

    /// Kênh của danh sách đang chọn: đã đọc thì trả luôn; chưa thì đọc tệp đã lưu (không tải mạng). nil = chưa có tệp.
    static func ensureLoaded() async -> IptvLoaded? {
        guard let l = activeList() else { return nil }
        if let x = locked({ $0.loaded?.listId == l.id ? $0.loaded : nil }) { return x }
        let path = rawFile(l)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        // Hai màn cùng hỏi lúc chưa đọc xong: chờ chung một lần đọc
        let task: Task<IptvLoaded?, Never> = locked { s in
            if let p = s.parsing, p.id == l.id { return p.task }
            let t = Task.detached(priority: .userInitiated) { parseFile(path, id: l.id) }
            s.parsing = (l.id, t)
            return t
        }
        let parsed = await task.value
        locked { s in
            if s.parsing?.id == l.id { s.parsing = nil }
            if let p = parsed, activeList()?.id == l.id, s.loaded?.listId != l.id {
                s.loaded = p
                s.version += 1
                s.filter = nil
            }
        }
        loadGuideCache(l.id)
        return locked { $0.loaded?.listId == l.id ? $0.loaded : nil } ?? parsed
    }

    /// Danh sách cũ quá bao lâu thì tải lại (ms).
    private static func maxAge(_ l: IptvLoaded?) -> Int64 {
        guard let l = l, l.hasMatches else { return listMaxAge }
        let now = nowSec()
        let waiting = l.channels.contains { c in
            c.kick > 0 && c.nolink && now >= c.kick - IptvParse.matchEarly && now < c.kick + Double(c.dur) * 60
        }
        return waiting ? waitingListMaxAge : matchListMaxAge
    }

    /// Màn Truyền hình đang mở (mỗi 30 giây / lúc quay lại): tải lại nếu đã quá hạn; vừa tải hỏng thì 3 phút sau mới thử lại.
    static func autoRefresh() async {
        guard let l = activeList(), l.file == nil, !loading, nowMs() - locked({ $0.lastTry }) >= autoRetryGap else { return }
        let have = await ensureLoaded()
        if have != nil && nowMs() - l.updated < maxAge(have) { return }
        Log.d("IPTV", "tự làm mới danh sách «\(l.name)»")
        _ = try? await refresh(force: false)
    }

    /// Tải lại danh sách nếu cũ hơn `seconds` (đang tải thì chờ xong) — trình phát tìm link mới.
    static func refreshIfOlder(than seconds: Int64) async throws {
        for _ in 0..<600 {
            if !locked({ $0.loading }) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if nowMs() - (activeList()?.updated ?? 0) > seconds * 1000 { try await refresh(force: true) }
    }

    /// Tải danh sách đang chọn (force: bỏ qua bản còn mới), rồi lịch nếu cũ. Lỗi: lý do (đã ghi vào danh sách).
    static func refresh(force: Bool) async throws {
        guard let l = activeList() else { throw AppError("Chưa có danh sách kênh") }
        let busy = locked { s -> Bool in
            if s.loading { return true }
            s.loading = true
            return false
        }
        if busy { return }
        var failure: Error?
        do {
            try await refreshInner(l, force: force)
        } catch {
            failure = error
        }
        locked {
            $0.loading = false
            $0.status = nil
            $0.version += 1
            $0.filter = nil
        }
        if let e = failure {
            let why = friendly(e)
            Log.d("IPTV", "tải danh sách «\(l.name)» lỗi: \(why)")
            updateList(l.id) { $0.err = why }
            throw AppError(why)
        }
        updateList(l.id) { $0.err = nil }
        _ = try? await refreshGuide(force: false)
    }

    private static func refreshInner(_ l: IptvList, force: Bool) async throws {
        let have = await ensureLoaded()
        let fresh = l.file != nil || nowMs() - l.updated < maxAge(have)
        if !force && fresh && have != nil && l.updated > 0 { return }
        locked { $0.lastTry = nowMs() }
        let t0 = nowMs()
        let path = rawFile(l)
        var sig: String?
        // Tệp sẽ đọc: danh sách theo địa chỉ thì đọc bản vừa tải (.part) trước — chỉ thay tệp cũ khi bản mới có kênh (cổng đăng
        // nhập Wi‑Fi / trang «hết hạn» trả HTML 200 thì giữ nguyên danh sách đang dùng được)
        var src = path
        if let url = l.url {
            setStatus("Đang tải danh sách kênh…")
            let part = dir.appendingPathComponent("\(l.id).part")
            let got = try await IptvFetch.download(url, to: part) { done in
                setStatus("Đang tải danh sách kênh… \(done >> 20) MB")
            }
            let s = "\(parseVersion):\(got.hash):\(got.size)"
            if s == l.sig && have != nil && FileManager.default.fileExists(atPath: path.path) {
                try? FileManager.default.removeItem(at: part)
                updateList(l.id) { $0.updated = nowMs() }
                Log.d("IPTV", "danh sách «\(l.name)» không đổi từ lần trước (\(nowMs() - t0) ms)")
                return
            }
            // Danh sách vừa bị xoá trong lúc tải: bỏ tệp tải về (không để lại tệp mồ côi)
            guard lists().contains(where: { $0.id == l.id }) else {
                try? FileManager.default.removeItem(at: part)
                return
            }
            src = part
            sig = s
        }
        setStatus("Đang đọc danh sách kênh…")
        let id = l.id
        let file = src
        let parsed = await Task.detached(priority: .userInitiated, operation: { parseFile(file, id: id) }).value
        guard let parsed = parsed, !parsed.channels.isEmpty else {
            if src != path { try? FileManager.default.removeItem(at: src) }
            guard let parsed = parsed else { throw AppError("Không đọc được danh sách.") }
            throw AppError(parsed.sawExtinf ? "Danh sách không có kênh nào." : "Tệp tải về không phải danh sách M3U.")
        }
        if src != path {
            try? FileManager.default.removeItem(at: path)
            do {
                try FileManager.default.moveItem(at: src, to: path)
            } catch {
                throw AppError("Không ghi được danh sách: \(error.localizedDescription)")
            }
        }
        Log.d("IPTV", "danh sách «\(l.name)» — \(parsed.entries) mục → \(parsed.channels.count) kênh, lịch \(parsed.epg ?? "không có") " +
            "(\(nowMs() - t0) ms)")
        // Trong lúc tải người dùng đã chọn danh sách khác: không đè danh sách đang dùng (lần sau đọc lại từ tệp)
        if activeList()?.id == l.id { locked { $0.loaded = parsed } }
        updateList(l.id) {
            $0.count = parsed.channels.count
            $0.updated = nowMs()
            $0.epg = parsed.epg
            if let s = sig { $0.sig = s }
        }
    }

    /// Tệp nén gzip (.gz — lịch XMLTV hay gặp): giải nén ra tệp bên cạnh (đọc dần, không giữ cả tệp trong RAM). nil = lỗi.
    static func gunzipIfNeeded(_ url: URL) -> URL? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = [UInt8](h.readData(ofLength: 4096))
        guard head.count >= 18, head[0] == 0x1F, head[1] == 0x8B, head[2] == 8 else { return url }
        // Đầu tệp gzip: 10 byte, rồi các phần tuỳ chọn theo cờ
        let flags = head[3]
        var off = 10
        if flags & 4 != 0 { off += 2 + Int(head[10]) + Int(head[11]) << 8 }
        if flags & 8 != 0 { while off < head.count && head[off] != 0 { off += 1 }; off += 1 }
        if flags & 16 != 0 { while off < head.count && head[off] != 0 { off += 1 }; off += 1 }
        if flags & 2 != 0 { off += 2 }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let end = size - 8 // 8 byte cuối: CRC32 + cỡ
        guard off < end else { return nil }
        let out = url.appendingPathExtension("unz")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        guard let w = try? FileHandle(forWritingTo: out) else { return nil }
        defer { try? w.close() }
        do {
            let filter = try OutputFilter(.decompress, using: .zlib, bufferCapacity: 1 << 20) { data in
                if let d = data { w.write(d) }
            }
            h.seek(toFileOffset: UInt64(off))
            var left = end - off
            while left > 0 {
                let d = h.readData(ofLength: min(left, 1 << 20))
                if d.isEmpty { break }
                left -= d.count
                try filter.write(d)
            }
            try filter.finalize()
        } catch {
            Log.d("IPTV", "giải nén \(url.lastPathComponent) lỗi: \(error)")
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    // MARK: - Lịch phát sóng

    static var epgOverride: String? {
        let v = Prefs.store.string(forKey: "iptv_epg_url")?.trimmingCharacters(in: .whitespaces) ?? ""
        return v.isEmpty ? nil : v
    }

    static func setEpgOverride(_ url: String?) {
        let v = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Prefs.store.set(v.isEmpty ? nil : v, forKey: "iptv_epg_url")
    }

    static func epgUrl() -> String? { epgOverride ?? activeList()?.epg }

    private static func guideFile(_ id: String) -> URL { dir.appendingPathComponent("epg-\(id).json") }

    private static func loadGuideCache(_ id: String) {
        if locked({ $0.guide?.list == id }) { return }
        guard let d = try? Data(contentsOf: guideFile(id)), let g = try? JSONDecoder().decode(IptvGuide.self, from: d) else { return }
        locked {
            $0.guide = g
            $0.version += 1
        }
    }

    static func guide() -> IptvGuide? {
        guard let id = activeList()?.id else { return nil }
        return locked { $0.guide?.list == id ? $0.guide : nil }
    }

    static func refreshGuide(force: Bool) async throws {
        guard let url = epgUrl() else { throw AppError("Danh sách không ghi địa chỉ lịch phát sóng (EPG)") }
        guard let l = activeList() else { throw AppError("Chưa có danh sách kênh") }
        guard let loaded = await ensureLoaded() else { throw AppError("Chưa tải danh sách kênh") }
        loadGuideCache(l.id)
        if let g = guide(), !force, g.src == url, nowMs() - g.fetched < guideMaxAge { return }
        let busy = locked { s -> Bool in
            if s.guideLoading { return true }
            s.guideLoading = true
            s.status = "Đang tải lịch phát sóng…"
            return false
        }
        if busy { return }
        let t0 = nowMs()
        let raw = dir.appendingPathComponent("epg-\(l.id).download")
        defer {
            try? FileManager.default.removeItem(at: raw)
            locked {
                $0.guideLoading = false
                $0.status = nil
                $0.version += 1
            }
        }
        _ = try await IptvFetch.download(url, to: raw) { _ in }
        let tids = Set(loaded.channels.compactMap { $0.tid })
        let keys = Set(loaded.channels.map { $0.k })
        let prog = await Task.detached(priority: .utility) { () -> [String: [IptvProgramme]]? in
            guard let plain = gunzipIfNeeded(raw), let r = IptvByteReader(url: plain) else { return nil }
            defer { if plain != raw { try? FileManager.default.removeItem(at: plain) } }
            let now = nowSec()
            return IptvParse.parseXmltv(r, tids: tids, keys: keys, from: now - 24 * 3600, to: now + 48 * 3600)
        }.value
        guard let p = prog else { throw AppError("Không đọc được tệp lịch phát sóng.") }
        let g = IptvGuide(list: l.id, src: url, fetched: nowMs(), prog: p)
        if let d = try? JSONEncoder().encode(g) { try? d.write(to: guideFile(l.id), options: .atomic) }
        Log.d("IPTV", "lịch \(url) — \(p.count) kênh có lịch (\(nowMs() - t0) ms)")
        locked { $0.guide = g }
    }

    // MARK: - Yêu thích / vừa xem / kênh hỏng / cài đặt

    static func favoriteKeys() -> [String] { Prefs.store.stringArray(forKey: Prefs.own("iptv_favs")) ?? [] }

    static func setFavorite(_ key: String, _ on: Bool) {
        var f = favoriteKeys().filter { $0 != key }
        if on { f.append(key) }
        Prefs.store.set(f, forKey: Prefs.own("iptv_favs"))
        changed()
    }

    static func recent() -> [IptvRecent] { Prefs.decode([IptvRecent].self, Prefs.own("iptv_recent")) ?? [] }

    private static func addRecent(_ c: IptvChannel, group: String) {
        if Prefs.privateMode { return }
        let item = IptvRecent(k: c.k, n: c.n, g: group, l: activeList()?.id, logo: c.logo, radio: c.radio ? true : nil)
        let list = [item] + recent().filter { $0.k != c.k }.prefix(11)
        Prefs.encode(list, Prefs.own("iptv_recent"))
    }

    private static func badMap() -> [String: String] { Prefs.decode([String: String].self, "iptv_bad") ?? [:] }

    static func badReason(_ url: String) -> String? { badMap()[url] }

    static func markBad(_ url: String, _ reason: String) {
        var m = badMap()
        if m.count > 500 { m = [:] }
        m[url] = reason
        Prefs.encode(m, "iptv_bad")
        changed()
    }

    static func clearBad() {
        Prefs.store.removeObject(forKey: "iptv_bad")
        changed()
    }

    static func clearBad(forKey key: String) {
        guard let l = locked({ $0.loaded }), let (_, c) = l.byKey(key) else { return }
        var m = badMap()
        for u in c.urls { m[u] = nil }
        Prefs.encode(m, "iptv_bad")
        changed()
    }

    private static func channelBad(_ c: IptvChannel, _ bad: [String: String]) -> String? {
        guard !c.urls.isEmpty, c.urls.allSatisfy({ bad[$0] != nil }) else { return nil }
        return bad[c.urls[0]]
    }

    /// Ẩn kênh mà mọi nguồn đều đã ghi «máy không giải mã được» (lỗi mạng thoáng qua không ghi).
    static var hideBad: Bool {
        get { Prefs.store.object(forKey: "iptv_hide_bad") as? Bool ?? true }
        set {
            Prefs.store.set(newValue, forKey: "iptv_hide_bad")
            changed()
        }
    }

    /// Nguồn lỗi thì tự sang nguồn sau.
    static var autoSource: Bool {
        get { Prefs.store.object(forKey: "iptv_auto_source") as? Bool ?? true }
        set { Prefs.store.set(newValue, forKey: "iptv_auto_source") }
    }

    // MARK: - Lọc / trang kênh cho giao diện

    private static func filtered(_ l: IptvLoaded, _ f: IptvFilter) -> [Int32] {
        let kids = Prefs.kids
        let hide = hideBad
        // Kênh yêu thích là của từng người xem (đổi người xem / đồng bộ không tăng version): khoá có cả người xem và
        // danh sách yêu thích, không thì hàng «Kênh yêu thích» của người mới hiện kênh của người trước
        let favList = f.favs ? favoriteKeys() : []
        let key = "\(l.listId)|\(f.group ?? -1)|\(f.favs)|\(f.q)|\(kids)|\(hide)|\(Prefs.profileId)|\(favList.joined(separator: "\u{1}"))"
        let version = locked { $0.version }
        if let c = locked({ $0.filter }), c.key == key, c.version == version { return c.ids }
        let favs = Set(favList)
        let bad = hide ? badMap() : [:]
        let q = f.q.trimmingCharacters(in: .whitespaces)
        let nq = IptvParse.norm(q)
        var ids: [Int32] = []
        for (i, c) in l.channels.enumerated() {
            if let g = f.group, c.g != g { continue }
            if f.favs && !favs.contains(c.k) { continue }
            if kids && !c.kids { continue }
            if hide && !bad.isEmpty && channelBad(c, bad) != nil { continue }
            if !q.isEmpty && !((!nq.isEmpty && c.k.contains(nq)) || c.num == q) { continue }
            ids.append(Int32(i))
        }
        // Danh sách có trận: đang đá (có link trước) → sắp đá (sớm trước) → kênh thường → đã xong (mới xong trước)
        if l.hasMatches {
            let now = nowSec()
            func rank(_ c: IptvChannel) -> Int {
                switch IptvParse.matchState(kick: c.kick, dur: c.dur, now: now) {
                case .live: return c.nolink ? 1 : 0
                case .later, .soon: return 2
                case .none: return 3
                case .over: return 4
                }
            }
            ids.sort { a, b in
                let (ca, cb) = (l.channels[Int(a)], l.channels[Int(b)])
                let (ra, rb) = (rank(ca), rank(cb))
                if ra != rb { return ra < rb }
                let ka = ra == 4 ? -ca.kick : ca.kick
                let kb = rb == 4 ? -cb.kick : cb.kick
                if ka != kb { return ka < kb }
                return a < b
            }
        }
        locked { $0.filter = (key, version, ids) }
        return ids
    }

    private static func view(_ l: IptvLoaded, _ ix: Int, guide: IptvGuide?, favs: Set<String>, bad: [String: String],
                             full: Bool) -> IptvChannelView {
        let c = l.channels[ix]
        let now = nowSec()
        let nolink = c.nolink
        var v = IptvChannelView(
            id: ix, k: c.k, n: c.n, g: c.g < l.groups.count ? l.groups[c.g] : "", num: c.num, logo: c.logo, radio: c.radio, vod: c.vod,
            kick: c.kick, dur: c.dur, nolink: nolink, sources: c.urls.count, fav: favs.contains(c.k),
            match: IptvParse.matchState(kick: c.kick, dur: c.dur, now: now),
            matchLine: IptvParse.matchLine(kick: c.kick, dur: c.dur, nolink: nolink, now: now), bad: channelBad(c, bad))
        if let g = guide {
            let p = g.programmes(c)
            v.now = p.first { $0.s <= now && now < $0.e }
            v.next = p.first { $0.s > now }
            if full { v.programmes = p }
        }
        if full {
            v.urls = c.urls.map { u in
                let h = c.headers(for: u)
                return IptvSource(url: u, referer: h.referer, ua: h.ua, bad: bad[u])
            }
            v.tid = c.tid
        }
        return v
    }

    /// Nhóm có kênh (theo hồ sơ trẻ em / ẩn kênh hỏng) + số kênh tất cả / yêu thích.
    static func groups() async -> IptvGroups {
        guard let l = await ensureLoaded() else { return IptvGroups() }
        let all = filtered(l, IptvFilter())
        var counts = [Int](repeating: 0, count: l.groups.count)
        for i in all { counts[l.channels[Int(i)].g] += 1 }
        let favs = filtered(l, IptvFilter(favs: true)).count
        let g = l.groups.enumerated().filter { counts[$0.offset] > 0 }.map { IptvGroup(id: $0.offset, name: $0.element, count: counts[$0.offset]) }
        return IptvGroups(groups: g, total: all.count, favs: favs, list: l.listId)
    }

    /// Một trang kênh của bộ lọc.
    static func page(_ f: IptvFilter, offset: Int, limit: Int) async -> (total: Int, items: [IptvChannelView]) {
        guard let l = await ensureLoaded() else { return (0, []) }
        let ids = filtered(l, f)
        let g = guide()
        let favs = Set(favoriteKeys())
        let bad = badMap()
        guard offset < ids.count else { return (ids.count, []) }
        let items = ids[offset..<min(ids.count, offset + limit)].enumerated().map { j, i -> IptvChannelView in
            var v = view(l, Int(i), guide: g, favs: favs, bad: bad, full: false)
            v.index = offset + j
            v.total = ids.count
            return v
        }
        return (ids.count, items)
    }

    /// Kênh ở vị trí `index` của bộ lọc (đủ nguồn + lịch) — trình phát.
    static func at(_ f: IptvFilter, _ index: Int) async -> IptvChannelView? {
        guard let l = await ensureLoaded() else { return nil }
        let ids = filtered(l, f)
        guard index >= 0, index < ids.count else { return nil }
        var v = view(l, Int(ids[index]), guide: guide(), favs: Set(favoriteKeys()), bad: badMap(), full: true)
        v.index = index
        v.total = ids.count
        return v
    }

    /// Vị trí của kênh có khoá `key` (hoặc số kênh `num`) trong bộ lọc; -1 = không có.
    static func indexOf(_ f: IptvFilter, key: String? = nil, num: String? = nil) async -> Int {
        guard let l = await ensureLoaded() else { return -1 }
        let ids = filtered(l, f)
        return ids.firstIndex { i in
            let c = l.channels[Int(i)]
            return (key != nil && c.k == key) || (num != nil && c.num == num)
        } ?? -1
    }

    /// Ghi kênh vừa xem (trình phát phát được).
    static func played(_ key: String) async {
        guard let l = await ensureLoaded(), let (_, c) = l.byKey(key) else { return }
        addRecent(c, group: c.g < l.groups.count ? l.groups[c.g] : "")
    }

    // MARK: - Hàng Truyền hình trên trang chủ

    /// Số ô tối đa mỗi hàng Truyền hình của trang chủ.
    static let homeMax = 16

    /// Kênh cho hàng «Trận đang / sắp đá»: đang đá có link trước, rồi đang đá chưa có hình, rồi sắp đá (bóng lăn sớm trước);
    /// một trận ở nhiều nhóm (cùng khoá) chỉ lấy một.
    static func pickLive(_ ch: [IptvChannel], now: Double, limit: Int) -> [Int] {
        var picked: [(rank: Int, kick: Double, i: Int)] = []
        for (i, c) in ch.enumerated() where c.kick > 0 {
            let r: Int
            switch IptvParse.matchState(kick: c.kick, dur: c.dur, now: now) {
            case .live: r = c.nolink ? 1 : 0
            case .soon: r = 2
            case .later: r = 3
            case .none, .over: continue
            }
            picked.append((r, c.kick, i))
        }
        picked.sort { ($0.rank, $0.kick, $0.i) < ($1.rank, $1.kick, $1.i) }
        var seen = Set<String>()
        var out: [Int] = []
        for p in picked where seen.insert(ch[p.i].k).inserted {
            out.append(p.i)
            if out.count >= limit { break }
        }
        return out
    }

    /// Đài cho hàng «Radio»: đài vừa nghe trước (theo thứ tự vừa nghe), rồi các đài khác theo thứ tự danh sách; mỗi khoá một ô.
    static func pickRadio(_ ch: [IptvChannel], recent: [String], limit: Int) -> [Int] {
        var first: [String: Int] = [:]
        for (i, c) in ch.enumerated() where c.radio && first[c.k] == nil { first[c.k] = i }
        var seen = Set<String>()
        var out: [Int] = []
        for k in recent {
            guard let i = first[k], seen.insert(k).inserted else { continue }
            out.append(i)
            if out.count >= limit { return out }
        }
        for (i, c) in ch.enumerated() where c.radio && seen.insert(c.k).inserted {
            out.append(i)
            if out.count >= limit { break }
        }
        return out
    }

    /// Dữ liệu các hàng Truyền hình của trang chủ: kênh vừa xem (kèm chương trình đang phát nếu thuộc danh sách đang dùng),
    /// yêu thích, trận đang / sắp đá, radio của danh sách đang dùng. Chưa có danh sách / chưa đọc được thì chỉ có kênh vừa xem.
    /// Hồ sơ trẻ em: không có trận đấu / radio.
    static func home(limit: Int = homeMax) async -> IptvHome {
        let recents = recent()
        let active = activeList()
        if active == nil && recents.isEmpty { return IptvHome() }
        let l = active == nil ? nil : await ensureLoaded()
        let now = nowSec()
        let g = guide()
        let favs = Set(favoriteKeys())
        var out = IptvHome(list: l?.listId)
        func item(_ ix: Int, _ id: String, index: Int, in l: IptvLoaded) -> IptvHomeItem {
            let v = view(l, ix, guide: g, favs: favs, bad: [:], full: false)
            var line = v.g
            var frac = -1.0
            var tag: String? = nil
            var live = false
            switch v.match {
            case .live:
                tag = "ĐANG ĐÁ"
                live = true
                if v.dur > 0 { frac = min(1, max(0, (now - v.kick) / Double(v.dur * 60))) }
            case .soon, .later:
                tag = "SẮP ĐÁ"
            case .none, .over:
                break
            }
            if v.match != .none {
                line = v.matchLine ?? line
            } else if let p = v.now {
                line = p.t
                if p.e > p.s { frac = min(1, max(0, (now - p.s) / (p.e - p.s))) }
            }
            if v.radio && tag == nil { tag = "RADIO" }
            return IptvHomeItem(id: id, k: v.k, list: l.listId, n: v.n, logo: v.logo, radio: v.radio, line: line, frac: frac, tag: tag,
                                live: live, index: index)
        }
        for (j, r) in recents.prefix(limit).enumerated() {
            if let l = l, r.l == nil || r.l == l.listId, let (ix, _) = l.byKey(r.k) {
                out.recent.append(item(ix, "r\(j)", index: -1, in: l))
            } else {
                let radio = r.radio == true
                out.recent.append(IptvHomeItem(id: "r\(j)", k: r.k, list: r.l, n: r.n, logo: r.logo, radio: radio, line: r.g, frac: -1,
                                               tag: radio ? "RADIO" : nil, live: false, index: -1))
            }
        }
        guard let l = l else { return out }
        for (j, i) in filtered(l, IptvFilter(favs: true)).prefix(limit).enumerated() {
            out.favs.append(item(Int(i), "f\(j)", index: j, in: l))
        }
        if !Prefs.kids {
            if l.hasMatches {
                for (j, i) in pickLive(l.channels, now: now, limit: limit).enumerated() {
                    out.live.append(item(i, "m\(j)", index: -1, in: l))
                }
            }
            let heard = recents.filter { $0.radio == true && ($0.l == nil || $0.l == l.listId) }.map { $0.k }
            for (j, i) in pickRadio(l.channels, recent: heard, limit: limit).enumerated() {
                out.radio.append(item(i, "a\(j)", index: -1, in: l))
            }
        }
        return out
    }

    // MARK: - Nhắc giờ phát / bóng lăn (giao diện hỏi `dueReminder` mỗi 15 giây khi app mở)

    private static func reminders() -> [IptvReminder] { Prefs.decode([IptvReminder].self, "iptv_reminders") ?? [] }

    /// Bật / tắt nhắc: `kick` = nhắc lúc bóng lăn (giờ trận), không thì «Nhắc tôi» 5 phút trước giờ phát `s`. true = vừa đặt.
    @discardableResult
    static func toggleReminder(key: String, name: String, title: String, s: Double, kick: Bool) -> Bool {
        let all = reminders()
        func same(_ r: IptvReminder) -> Bool { r.k == key && r.kick == kick && (kick || abs(r.s - s) < 1) }
        if all.contains(where: same) {
            Prefs.encode(all.filter { !same($0) }, "iptv_reminders")
            return false
        }
        let at = kick ? Int64(s * 1000) : max(Int64((s - 300) * 1000), nowMs() + 5000)
        Prefs.encode(all + [IptvReminder(k: key, n: name, t: title, s: s, at: at, kick: kick)], "iptv_reminders")
        return true
    }

    static func hasReminder(key: String, s: Double? = nil, kick: Bool) -> Bool {
        reminders().contains { r in r.k == key && r.kick == kick && (kick || s.map { abs(r.s - $0) < 1 } ?? true) }
    }

    /// Nhắc đã tới giờ (lấy ra khỏi danh sách); bỏ nhắc quá cũ (đã qua 30 phút).
    static func dueReminder() -> IptvReminder? {
        let now = nowMs()
        var all = reminders()
        guard let i = all.firstIndex(where: { $0.at <= now }) else { return nil }
        var r = all.remove(at: i)
        Prefs.encode(all, "iptv_reminders")
        if Double(now) / 1000 > r.s + 30 * 60 { return nil }
        r.text = r.kick ? "Bóng lăn: \(r.n)" : "\(r.t) lúc \(IptvParse.clock(r.s)) trên \(r.n)"
        return r
    }

    /// Cổng gỡ lỗi: quên dấu tệp (lần tải sau đọc lại cả danh sách).
    static func forgetSignature() {
        guard let l = activeList() else { return }
        updateList(l.id) { $0.sig = nil }
    }
}

// MARK: - Tải tệp lớn (danh sách / lịch) xuống đĩa

enum IptvFetch {
    /// Tải `url` vào tệp `to`, trả (SHA-1, cỡ). Qua mạng của app (DNS mã hoá, vượt chặn, proxy); lỗi kết nối (không phải mã lỗi
    /// HTTP) mà không bật proxy thì thử mạng của máy — DNS mã hoá chỉ lấy một địa chỉ của tên miền, địa chỉ đó chết thì hỏng
    /// (gặp trên tivi 16/11 với dịch vụ rút gọn link; bản Legacy cũng thử lại bằng mạng của máy).
    static func download(_ url: String, headers: [String: String] = [:], to: URL,
                         progress: @escaping (Int64) -> Void) async throws -> (hash: String, size: Int64) {
        let req = try Http.request(url, headers: headers)
        do {
            return try await Download(file: to, progress: progress).run(req, config(direct: false))
        } catch where !(error is Http.HttpError) && !(error is AppError) && !AppProxy.active && AppProxy.cfDictionary != nil {
            // Lỗi kết nối nào cũng vậy (không chỉ URLError: lỗi cổng nội bộ trả về là lỗi CFNetwork, không đổi được thành URLError)
            Log.d("IPTV", "mạng của app lỗi với \(url) (\(error.localizedDescription)) — thử mạng của máy")
            return try await Download(file: to, progress: progress).run(req, config(direct: true))
        }
    }

    private static func config(direct: Bool) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 900
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        if !direct, let p = AppProxy.cfDictionary { c.connectionProxyDictionary = p }
        return c
    }

    private final class Download: NSObject, URLSessionDataDelegate {
        let file: URL
        let progress: (Int64) -> Void
        private var handle: FileHandle?
        private var hasher = Insecure.SHA1()
        private var size: Int64 = 0
        private var shown: Int64 = 0
        private var cont: CheckedContinuation<(hash: String, size: Int64), Error>?
        private var failure: Error?

        init(file: URL, progress: @escaping (Int64) -> Void) {
            self.file = file
            self.progress = progress
        }

        func run(_ req: URLRequest, _ config: URLSessionConfiguration) async throws -> (hash: String, size: Int64) {
            try await withCheckedThrowingContinuation { c in
                cont = c
                let q = OperationQueue()
                q.maxConcurrentOperationCount = 1
                let s = URLSession(configuration: config, delegate: self, delegateQueue: q)
                s.dataTask(with: req).resume()
                s.finishTasksAndInvalidate()
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 200
            if code >= 400 {
                failure = Http.HttpError(code: code)
                completionHandler(.cancel)
                return
            }
            try? FileManager.default.removeItem(at: file)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            handle = try? FileHandle(forWritingTo: file)
            if handle == nil { failure = AppError("Không ghi được tệp tải về.") }
            completionHandler(handle == nil ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            handle?.write(data)
            hasher.update(data: data)
            size += Int64(data.count)
            if size - shown >= 2 << 20 {
                shown = size
                progress(size)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle?.close()
            handle = nil
            guard let c = cont else { return }
            cont = nil
            if let e = failure ?? error {
                try? FileManager.default.removeItem(at: file)
                c.resume(throwing: e)
            } else {
                let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                c.resume(returning: (hex, size))
            }
        }
    }
}
