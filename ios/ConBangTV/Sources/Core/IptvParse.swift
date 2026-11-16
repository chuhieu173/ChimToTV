import Foundation

// Truyền hình (IPTV) — phần đọc thuần (có test, CoreTests/IptvTests.swift): dòng M3U, tên kênh, giờ trận, lịch XMLTV.
// Cùng cách đọc với bản Legacy (CBIPTV.m), bản tivi (IptvParse.kt) và lõi Rust của Windows / Linux (linux/core/src/iptv.rs).

/// Trạng thái kênh trận đấu theo giờ bóng lăn.
enum IptvMatch: String {
    case none, later, soon, live, over
}

/// Một mục của danh sách M3U (một dòng #EXTINF + dòng địa chỉ).
struct IptvEntry {
    var name: String
    var group: String
    var url: String
    var attrs: [String: String]
    var referer: String?
    var ua: String?
}

/// Nguồn các dòng chữ (tệp trên máy / chuỗi trong test).
protocol IptvLines: AnyObject {
    func nextLine() -> String?
}

/// Đọc tệp theo từng khối 1 MB (không giữ cả tệp trong RAM).
final class IptvByteReader: IptvLines {
    private let handle: FileHandle
    private var buf: [UInt8] = []
    private var pos = 0
    private var eof = false
    private var line: [UInt8] = []

    init?(url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        handle = h
    }

    deinit { try? handle.close() }

    private func fill() -> Bool {
        if eof { return false }
        let d = handle.readData(ofLength: 1 << 20)
        if d.isEmpty {
            eof = true
            return false
        }
        buf = [UInt8](d)
        pos = 0
        return true
    }

    /// Thêm vào `out` các byte tới hết `delim` (kể cả `delim`); false = hết tệp, không đọc được gì.
    func readUntil(_ delim: UInt8, _ out: inout [UInt8]) -> Bool {
        var any = false
        while true {
            if pos >= buf.count, !fill() { return any }
            if let i = buf[pos...].firstIndex(of: delim) {
                out.append(contentsOf: buf[pos...i])
                pos = i + 1
                return true
            }
            out.append(contentsOf: buf[pos...])
            pos = buf.count
            any = true
        }
    }

    func nextLine() -> String? {
        line.removeAll(keepingCapacity: true)
        guard readUntil(0x0A, &line) else { return nil }
        while let l = line.last, l == 0x0A || l == 0x0D { line.removeLast() }
        return String(decoding: line, as: UTF8.self)
    }
}

/// Dòng của một chuỗi (test).
final class IptvStringLines: IptvLines {
    private var lines: [String]
    private var i = 0

    init(_ text: String) { lines = text.components(separatedBy: "\n") }

    func nextLine() -> String? {
        guard i < lines.count else { return nil }
        i += 1
        return lines[i - 1]
    }
}

/// Đọc danh sách M3U theo từng dòng: #EXTINF, #EXTGRP, #EXTVLCOPT http-referrer / http-user-agent, «url|Referer=…&User-Agent=…»
/// (kiểu Kodi). `epg` = địa chỉ lịch ghi ở dòng #EXTM3U.
final class IptvReader {
    private var attrs: [String: String] = [:]
    private var name: String?
    private var group: String?
    private var referer: String?
    private var ua: String?
    private var started = false
    private(set) var epg: String?
    private(set) var sawExtinf = false

    func line(_ raw: String) -> IptvEntry? {
        var r = Substring(raw)
        if !started {
            started = true
            if r.hasPrefix("\u{FEFF}") { r = r.dropFirst() }
        }
        let l = r.trimmingCharacters(in: .whitespacesAndNewlines)
        if l.isEmpty { return nil }
        if l.hasPrefix("#EXTM3U") {
            let h = IptvParse.attrs(l)
            if let v = h["url-tvg"] ?? h["x-tvg-url"] ?? h["tvg-url"], let u = IptvParse.firstUrl(v) { epg = u }
        } else if l.hasPrefix("#EXTINF") {
            sawExtinf = true
            let (n, head) = IptvParse.extinfName(l)
            attrs = IptvParse.attrs(head)
            name = (n?.isEmpty == false) ? n : attrs["tvg-name"]
            group = attrs["group-title"]
            referer = nil
            ua = nil
        } else if l.hasPrefix("#EXTGRP:") {
            group = String(l.dropFirst(8)).trimmingCharacters(in: .whitespaces)
        } else if l.hasPrefix("#EXTVLCOPT:") {
            let o = l.dropFirst(11)
            if let eq = o.firstIndex(of: "=") {
                let k = o[..<eq].lowercased()
                let v = String(o[o.index(after: eq)...])
                if k == "http-referrer" || k == "http-referer" { referer = v }
                if k == "http-user-agent" { ua = v }
            }
        } else if !l.hasPrefix("#") {
            var url = l
            if let bar = l.firstIndex(of: "|") {
                for kv in l[l.index(after: bar)...].split(separator: "&") {
                    guard let eq = kv.firstIndex(of: "=") else { continue }
                    let raw = String(kv[kv.index(after: eq)...])
                    let v = raw.removingPercentEncoding ?? raw
                    switch kv[..<eq].lowercased() {
                    case "referer", "referrer": referer = v
                    case "user-agent": ua = v
                    default: break
                    }
                }
                url = String(l[..<bar])
            }
            var out: IptvEntry?
            if url.hasPrefix("http://") || url.hasPrefix("https://") {
                let n = (name?.isEmpty == false) ? name! : IptvParse.lastSegment(url)
                let g = (group?.isEmpty == false) ? group! : "Khác"
                out = IptvEntry(name: n, group: g, url: url, attrs: attrs, referer: referer, ua: ua)
            }
            attrs = [:]
            name = nil
            group = nil
            referer = nil
            ua = nil
            return out
        }
        return nil
    }
}

/// Giờ bóng lăn tìm thấy trong tên kênh (giây từ 1970) + vị trí chữ ghi giờ (UTF-16, để bỏ khỏi tên).
struct IptvKick {
    let at: Double
    let range: NSRange
}

enum IptvParse {
    /// Kênh trận đấu thường lên sóng trước giờ bóng lăn chừng này (giây).
    static let matchEarly: Double = 30 * 60

    private static func keyChar(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x2D
    }

    /// Thuộc tính `khoá="giá trị"` của dòng #EXTINF / #EXTM3U (khoá chữ thường).
    static func attrs(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        let b = Array(s.utf8)
        let n = b.count
        var i = 0
        while i + 1 < n {
            guard b[i] == 0x3D, b[i + 1] == 0x22 else {
                i += 1
                continue
            }
            var k = i
            while k > 0 && keyChar(b[k - 1]) { k -= 1 }
            var e = i + 2
            while e < n && b[e] != 0x22 { e += 1 }
            if e >= n { break }
            if k < i {
                out[String(decoding: b[k..<i], as: UTF8.self).lowercased()] = String(decoding: b[(i + 2)..<e], as: UTF8.self)
            }
            i = e + 1
        }
        return out
    }

    /// Tên kênh sau dấu phẩy đầu tiên nằm ngoài ngoặc kép của dòng #EXTINF; kèm phần đầu dòng (thuộc tính).
    static func extinfName(_ line: String) -> (name: String?, head: String) {
        var quoted = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "\"" {
                quoted.toggle()
            } else if c == "," && !quoted {
                return (line[line.index(after: i)...].trimmingCharacters(in: .whitespaces), String(line[..<i]))
            }
            i = line.index(after: i)
        }
        return (nil, line)
    }

    /// Địa chỉ http đầu tiên trong chuỗi nhiều địa chỉ cách nhau bằng dấu phẩy (url-tvg="a.xml,b.xml.gz").
    static func firstUrl(_ s: String) -> String? {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
    }

    static func lastSegment(_ url: String) -> String {
        var u = Substring(url.before("?"))
        while u.hasSuffix("/") { u = u.dropLast() }
        let s = u.split(separator: "/", omittingEmptySubsequences: false).last ?? u
        return s.isEmpty ? url : String(s)
    }

    /// Phần đường dẫn (chữ thường) của địa chỉ.
    static func pathOf(_ url: String) -> String {
        var rest = Substring(url)
        if let r = url.range(of: "://") { rest = url[r.upperBound...] }
        guard let slash = rest.firstIndex(of: "/") else { return "/" }
        let p = rest[slash...]
        let end = p.firstIndex { $0 == "?" || $0 == "#" } ?? p.endIndex
        return p[..<end].lowercased()
    }

    static func extOfPath(_ path: String) -> String {
        let last = path.split(separator: "/", omittingEmptySubsequences: false).last ?? Substring(path)
        guard let d = last.lastIndex(of: ".") else { return "" }
        return String(last[last.index(after: d)...])
    }

    static func extOf(_ url: String) -> String { extOfPath(pathOf(url)) }

    /// Luồng HTTP-FLV (kênh thể thao): xếp sau HLS.
    static func isFlv(_ url: String) -> Bool { extOf(url) == "flv" }

    /// Link giả «không có tín hiệu» mà danh sách thể thao để cho trận chưa có link thật (…/no-signal/low.m3u8: một ảnh 10 s).
    static func isPlaceholder(_ url: String) -> Bool {
        let p = pathOf(url)
        return p.contains("nosignal") || p.contains("no-signal") || p.contains("no_signal")
    }

    /// Thứ tự nguồn của một kênh: HLS / khác → FLV → link giả.
    static func sourceRank(_ url: String) -> Int { isPlaceholder(url) ? 2 : isFlv(url) ? 1 : 0 }

    private static let vodExt: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "webm", "mpg", "mpeg", "wmv", "3gp"]

    /// Phim / tập phim (VOD) của danh sách Xtream: tệp video, hoặc đường dẫn /movie/ /series/. Phát được tua.
    static func isVodPath(_ p: String) -> Bool {
        vodExt.contains(extOfPath(p)) || p.contains("/movie/") || p.contains("/series/")
    }

    static func isVod(_ url: String) -> Bool { isVodPath(pathOf(url)) }

    /// Đài radio: danh sách ghi `radio="true"`, nhóm «Radio» / «Phát thanh» / «Truyền thanh» (tên nhóm đã chuẩn hoá), hoặc link
    /// tệp tiếng / danh sách của đài (.mp3, .aac, .pls).
    static func isRadio(_ attrs: [String: String], groupNorm: String, ext: String) -> Bool {
        if let r = attrs["radio"]?.lowercased(), r == "true" || r == "1" { return true }
        if groupNorm.contains("radio") || groupNorm.contains("phatthanh") || groupNorm.contains("truyenthanh") { return true }
        return ext == "mp3" || ext == "aac" || ext == "pls"
    }

    static let kidsWords = ["thieunhi", "kid", "child", "cartoon", "hoathinh", "disney", "nick", "boomerang", "baby", "junior", "anime"]

    /// Hồ sơ trẻ em: kênh nhóm thiếu nhi / hoạt hình.
    static func isKids(groupNorm: String, key: String) -> Bool {
        kidsWords.contains { groupNorm.contains($0) || key.contains($0) }
    }

    /// Bỏ các đoạn «(…)» / «[…]» (cả khoảng trắng ngay trước nếu `spaces`). Ngoặc không đóng thì giữ.
    private static func dropBrackets(_ s: String, spaces: Bool) -> String {
        let c = Array(s)
        var out: [Character] = []
        out.reserveCapacity(c.count)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "(" || ch == "[" {
                let close: Character = ch == "(" ? ")" : "]"
                if let j = c[(i + 1)...].firstIndex(of: close) {
                    if spaces { while let l = out.last, l.isWhitespace { out.removeLast() } }
                    i = j + 1
                    continue
                }
            }
            out.append(ch)
            i += 1
        }
        return String(out)
    }

    private static let tails = ["backup", "1080p", "720p", "uhd", "fhd", "hd", "sd", "4k"].map { Array($0.utf8) }

    /// Tên chuẩn hoá để so / tìm: bỏ phần trong ngoặc, bỏ dấu, chữ thường, chỉ giữ chữ / số, bỏ «HD», «FHD»… ở cuối.
    static func norm(_ name: String) -> String {
        if name.isEmpty { return "" }
        var s = name
        if s.contains("(") || s.contains("[") {
            let bare = dropBrackets(s, spaces: false)
            if !bare.trimmingCharacters(in: .whitespaces).isEmpty { s = bare }
        }
        var t: [UInt8] = []
        if s.utf8.allSatisfy({ $0 < 0x80 }) {
            for b in s.utf8 {
                if (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x7A) {
                    t.append(b)
                } else if b >= 0x41 && b <= 0x5A {
                    t.append(b + 32)
                }
            }
        } else {
            let lower = s.lowercased().replacingOccurrences(of: "đ", with: "d").decomposedStringWithCanonicalMapping
            var keep = String.UnicodeScalarView()
            for u in lower.unicodeScalars {
                let p = u.properties
                switch p.generalCategory {
                case .nonspacingMark, .spacingMark, .enclosingMark: continue
                default: break
                }
                if p.isAlphabetic || p.numericType != nil { keep.append(u) }
            }
            t = Array(String(keep).utf8)
        }
        var end = t.count
        while true {
            let before = end
            for x in tails where end >= x.count && t[(end - x.count)..<end].elementsEqual(x) {
                end -= x.count
                break
            }
            if end == before || end == 0 { break }
        }
        return String(decoding: end > 0 ? t[0..<end] : t[0...], as: UTF8.self)
    }

    /// Mã nước đầu tên kiểu Xtream: «|UK| SPORT 1», «DE| ZDF» → độ dài phần mã (kể cả khoảng trắng sau), 0 = không có.
    private static func countryTagLength(_ s: String) -> Int {
        let b = Array(s.utf8)
        var i = 0
        if i < b.count && b[i] == 0x7C { i += 1 }
        let start = i
        while i < b.count && i - start < 5 && ((b[i] >= 0x41 && b[i] <= 0x5A) || (b[i] >= 0x30 && b[i] <= 0x39)) { i += 1 }
        guard i - start >= 2, i < b.count, b[i] == 0x7C else { return 0 }
        i += 1
        while i < b.count && (b[i] == 0x20 || b[i] == 0x09) { i += 1 }
        return i
    }

    /// Tên hiển thị của kênh thường: bỏ mã nước đầu tên kiểu Xtream («|UK| SPORT 1», «DE| ZDF») và phần trong ngoặc.
    static func displayName(_ name: String) -> String {
        var n = name
        if n.contains("|") {
            let len = countryTagLength(n)
            if len > 0 {
                let t = String(decoding: Array(n.utf8)[len...], as: UTF8.self)
                if !t.isEmpty { n = t }
            }
        }
        if !n.contains("(") && !n.contains("[") { return n.trimmingCharacters(in: .whitespaces) }
        let b = dropBrackets(n, spaces: true).trimmingCharacters(in: .whitespaces)
        return b.isEmpty ? n : b
    }

    // ---- Giờ trận («20:00 16/11 ⚽ A vs B (BLV …) [hls]») ----

    private static let timeFirst = try! NSRegularExpression(
        pattern: #"(\d{1,2})[:hH](\d{2})\s*[-,|·]?\s*(?:ngày\s*)?(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?"#)
    private static let dateFirst = try! NSRegularExpression(
        pattern: #"(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\s*[-,|·]?\s*(\d{1,2})[:hH](\d{2})"#)
    private static let matchy = try! NSRegularExpression(
        pattern: #"\bvs?\.?\s|\s[-–]\s|BLV|⚽|🏀|🎾|🥎|🏐|🏸|🏒|🥊|🏈|⚾"#, options: [.caseInsensitive])
    private static let tags = try! NSRegularExpression(pattern: #"\[[^\]]*\]"#)
    private static let spaces = try! NSRegularExpression(pattern: #"\s{2,}"#)
    private static let stamp = try! NSRegularExpression(pattern: #"[-_ ]*\d{4}-\d{2}-\d{2}([T_ ]?[\d.:-]*)?$"#)

    private static func boundaryOk(_ ns: NSString, _ r: NSRange) -> Bool {
        func bad(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length else { return false }
            let c = ns.character(at: i)
            return (c >= 0x30 && c <= 0x39) || c == 0x3A || c == 0x2F
        }
        return !bad(r.location - 1) && !bad(r.location + r.length)
    }

    /// Ngày (từ 1970-01-01) của một ngày dương lịch (Howard Hinnant).
    static func daysFromCivil(_ year: Int, _ m: Int, _ d: Int) -> Int {
        let y = year - (m <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// Năm dương lịch của một ngày (từ 1970-01-01).
    static func yearOfDays(_ days: Int) -> Int {
        let z = days + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let m = mp < 10 ? mp + 3 : mp - 9
        return yoe + era * 400 + (m <= 2 ? 1 : 0)
    }

    /// Giờ trận ghi trong tên kênh → giây từ 1970. Giờ Việt Nam (UTC+7); không ghi năm thì lấy năm gần bây giờ nhất.
    static func kickoff(_ name: String, now: Double) -> IptvKick? {
        guard name.contains("/") else { return nil }
        let ns = name as NSString
        let all = NSRange(location: 0, length: ns.length)
        func found(_ re: NSRegularExpression) -> NSTextCheckingResult? {
            re.matches(in: name, range: all).first { boundaryOk(ns, $0.range) }
        }
        var tf = true
        var caps = found(timeFirst)
        if caps == nil {
            tf = false
            caps = found(dateFirst)
        }
        guard let c = caps else { return nil }
        func g(_ i: Int) -> Int {
            let r = c.range(at: i)
            return r.location == NSNotFound ? 0 : Int(ns.substring(with: r)) ?? 0
        }
        let (h, mi, d, mo) = tf ? (g(1), g(2), g(3), g(4)) : (g(4), g(5), g(1), g(2))
        var y = tf ? g(5) : g(3)
        guard h <= 23, mi <= 59, (1...31).contains(d), (1...12).contains(mo) else { return nil }
        if (1..<100).contains(y) { y += 2000 }
        let nowYear = yearOfDays(Int(((now + 7 * 3600) / 86400).rounded(.down)))
        let years = y != 0 ? [y] : [nowYear - 1, nowYear, nowYear + 1]
        var best = Double.nan
        for yy in years {
            let t = Double(daysFromCivil(yy, mo, d)) * 86400 + Double(h * 3600 + mi * 60 - 7 * 3600)
            if best.isNaN || abs(t - now) < abs(best - now) { best = t }
        }
        return IptvKick(at: best, range: c.range)
    }

    static func isMatchName(_ name: String) -> Bool {
        matchy.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil
    }

    /// Thời lượng trận (phút) theo môn ghi trong tên — để biết lúc nào «Đã xong».
    static func matchMinutes(_ name: String) -> Int {
        if name.contains("⚽") { return 130 }
        if name.contains("🎾") || name.contains("🥎") { return 200 }
        return 150
    }

    private static func replace(_ re: NSRegularExpression, _ s: String, _ with: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: with)
    }

    /// Emoji mới hơn máy cũ vẽ được (🟢 🥅…): bỏ (🥎 → 🎾) — cùng tên với bản tivi / Legacy.
    static func oldEmoji(_ input: String) -> String {
        let s = input.replacingOccurrences(of: "🥎", with: "🎾")
        var keep = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let cp = u.value
            if cp >= 0x1F900 || (0x1F7E0...0x1F7FF).contains(cp) || (0x1F3CF...0x1F3D3).contains(cp) ||
                (0x1F3F8...0x1F3FF).contains(cp) || (0x1F6D0...0x1F6FF).contains(cp) { continue }
            keep.append(u)
        }
        return replace(spaces, String(keep), " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tên trận hiển thị: bỏ chỗ ghi giờ và các thẻ «[hls]», «[FHD]»; giữ «(BLV …)» — mỗi BLV là một kênh.
    static func matchName(_ name: String, _ kick: IptvKick) -> String {
        let ns = name as NSString
        let n = ns.substring(to: kick.range.location) + " " + ns.substring(from: kick.range.location + kick.range.length)
        let bare = oldEmoji(replace(tags, n, ""))
        return bare.isEmpty ? n.trimmingCharacters(in: .whitespaces) : bare
    }

    static func matchState(kick: Double, dur: Int, now: Double) -> IptvMatch {
        if kick <= 0 { return .none }
        if now < kick - matchEarly { return .later }
        if now < kick { return .soon }
        if now < kick + Double(dur) * 60 { return .live }
        return .over
    }

    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// «19:00» giờ máy.
    static func clock(_ t: Double) -> String { hm.string(from: Date(timeIntervalSince1970: t)) }

    private static func localDay(_ t: Double) -> (days: Int, day: Int, month: Int) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
        let (y, m, d) = (c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        return (daysFromCivil(y, m, d), d, m)
    }

    /// «20:00», «02:45 mai», «20:00 hôm qua», «20:00 18/11» (giờ máy).
    static func kickText(_ kick: Double, now: Double) -> String {
        let c = clock(kick)
        let k = localDay(kick)
        switch k.days - localDay(now).days {
        case 0: return c
        case 1: return "\(c) mai"
        case -1: return "\(c) hôm qua"
        default: return "\(c) \(k.day)/\(k.month)"
        }
    }

    /// «Sắp đá 20:00 · còn 25 phút», «● Đang đá · bóng lăn 20:00», «Đã xong · đá lúc 20:00»; nil = kênh thường.
    static func matchLine(kick: Double, dur: Int, nolink: Bool, now: Double) -> String? {
        let when = kickText(kick, now: now)
        let left = Int(((kick - now) / 60).rounded(.up))
        switch matchState(kick: kick, dur: dur, now: now) {
        case .none: return nil
        case .later where left >= 24 * 60: return "Sắp đá \(when)"
        case .later where left >= 60: return "Sắp đá \(when) · còn \(left / 60) giờ \(String(format: "%02d", left % 60)) phút"
        case .later: return "Sắp đá \(when) · còn \(left) phút"
        case .soon: return "Sắp đá \(when) · còn \(max(left, 1)) phút"
        case .live: return nolink ? "● Đang đá · danh sách chưa có link" : "● Đang đá · bóng lăn \(when)"
        case .over: return "Đã xong · đá lúc \(when)"
        }
    }

    /// «20261116190000 +0700» → giây từ 1970 (UTC).
    static func xmltvTime(_ s: String) -> Double? {
        let b = Array(s.utf8)
        guard b.count >= 12 else { return nil }
        let widths = [4, 2, 2, 2, 2, 2]
        var v = [Int](repeating: 0, count: 6)
        var p = 0
        func digit(_ i: Int) -> Bool { i < b.count && b[i] >= 0x30 && b[i] <= 0x39 }
        for (i, w) in widths.enumerated() {
            if i == 5 && !digit(p) { break }
            for _ in 0..<w {
                guard digit(p) else { return nil }
                v[i] = v[i] * 10 + Int(b[p] - 0x30)
                p += 1
            }
        }
        var t = Double(daysFromCivil(v[0], v[1], v[2]) * 86400 + v[3] * 3600 + v[4] * 60 + v[5])
        while p < b.count && b[p] == 0x20 { p += 1 }
        if p + 4 < b.count, b[p] == 0x2B || b[p] == 0x2D, (1...4).allSatisfy({ digit(p + $0) }) {
            let d = { (i: Int) in Int(b[p + i] - 0x30) }
            let off = Double((d(1) * 10 + d(2)) * 3600 + (d(3) * 10 + d(4)) * 60)
            t -= b[p] == 0x2B ? off : -off
        }
        return t
    }

    /// Danh sách phát là đoạn phim ngắn có hồi kết (hình chờ «không có tín hiệu» thay cho luồng trực tiếp).
    static func isPlaceholderPlaylist(_ m3u8: String) -> Bool {
        guard m3u8.contains("#EXT-X-ENDLIST"), !m3u8.contains("#EXT-X-STREAM-INF") else { return false }
        var total = 0.0
        for l in m3u8.split(whereSeparator: \.isNewline) where l.hasPrefix("#EXTINF:") {
            total += Double(l.dropFirst(8).split(separator: ",").first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        }
        return total < 120
    }

    /// Tên danh sách lấy từ tên tệp: «4k viptv-playlist---2026-11-11T131814-437.m3u» → «4k viptv-playlist».
    static func nameFromFile(_ file: String) -> String {
        var base = file.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? file
        if let dot = base.lastIndex(of: ".") { base = String(base[..<dot]) }
        let n = replace(stamp, base, "").replacingOccurrences(of: "_", with: " ").trimmingChars(" -.")
        return n.isEmpty ? "Danh sách từ tệp" : String(n.prefix(40))
    }

    /// Tên danh sách lấy từ địa chỉ: tên tệp (bỏ đuôi), không có thì tên máy chủ.
    static func nameFromUrl(_ u: String) -> String {
        let c = URLComponents(string: u)
        var path = c?.path ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        var file = path.split(separator: "/").last.map(String.init) ?? ""
        if let dot = file.lastIndex(of: ".") { file = String(file[..<dot]) }
        file = file.replacingOccurrences(of: "_", with: " ")
        if file.count > 2 { return file }
        return c?.host ?? "Danh sách kênh"
    }

    // ---- Lịch phát sóng (XMLTV) ----

    private static func xmlUnescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            guard let semi = rest.firstIndex(of: ";"), rest.distance(from: rest.startIndex, to: semi) < 12 else {
                out += "&"
                rest = rest.dropFirst()
                continue
            }
            let ent = rest[rest.index(after: rest.startIndex)..<semi]
            var ch: Character?
            switch ent {
            case "amp": ch = "&"
            case "lt": ch = "<"
            case "gt": ch = ">"
            case "quot": ch = "\""
            case "apos": ch = "'"
            default:
                if ent.hasPrefix("#x") || ent.hasPrefix("#X") {
                    ch = UInt32(ent.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(Character.init)
                } else if ent.hasPrefix("#") {
                    ch = UInt32(ent.dropFirst()).flatMap(Unicode.Scalar.init).map(Character.init)
                }
            }
            if let c = ch {
                out.append(c)
                rest = rest[rest.index(after: semi)...]
            } else {
                out += "&"
                rest = rest.dropFirst()
            }
        }
        out += rest
        return out
    }

    /// Giá trị thuộc tính `name="…"` (hoặc '…') trong thẻ XML.
    static func xmlAttr(_ tag: [UInt8], _ name: String) -> String? {
        let nb = Array(name.utf8)
        let n = tag.count
        func space(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        var i = 0
        while i + nb.count <= n {
            guard tag[i..<(i + nb.count)].elementsEqual(nb) else {
                i += 1
                continue
            }
            let beforeOk = i == 0 || space(tag[i - 1])
            var j = i + nb.count
            while j < n && space(tag[j]) { j += 1 }
            if beforeOk && j < n && tag[j] == 0x3D {
                j += 1
                while j < n && space(tag[j]) { j += 1 }
                if j < n && (tag[j] == 0x22 || tag[j] == 0x27) {
                    let q = tag[j]
                    guard let end = tag[(j + 1)...].firstIndex(of: q) else { return nil }
                    return xmlUnescape(String(decoding: tag[(j + 1)..<end], as: UTF8.self))
                }
            }
            i += nb.count
        }
        return nil
    }

    private static func bytesEqual(_ a: ArraySlice<UInt8>, _ s: StaticString) -> Bool {
        a.count == s.utf8CodeUnitCount && a.elementsEqual(UnsafeBufferPointer(start: s.utf8Start, count: s.utf8CodeUnitCount))
    }

    /// Đọc XMLTV từng thẻ (không giữ cả tệp, chịu được tệp hơi sai cú pháp): chỉ chương trình của kênh có tvg-id trong `tids`
    /// hoặc tên chuẩn hoá (display-name) trong `keys`, từ `from` tới `to`. Trả khoá → chương trình (đã xếp theo giờ).
    static func parseXmltv(_ r: IptvByteReader, tids: Set<String>, keys: Set<String>, from: Double, to: Double) -> [String: [IptvProgramme]] {
        var out: [String: [IptvProgramme]] = [:]
        var alias: [String: String] = [:] // "" = kênh không cần
        var chan: String?
        var prog: (key: String, s: Double, e: Double?)?
        var title: String?
        var want = 0 // 1 = display-name, 2 = title
        var text: [UInt8] = []
        var tag: [UInt8] = []
        while true {
            text.removeAll(keepingCapacity: true)
            guard r.readUntil(0x3C, &text) else { break }
            if text.last == 0x3C { text.removeLast() }
            tag.removeAll(keepingCapacity: true)
            guard r.readUntil(0x3E, &tag) else { break }
            // Chú thích có thể chứa '>': đọc tới hết «-->»
            if tag.count >= 3 && tag[0] == 0x21 && tag[1] == 0x2D && tag[2] == 0x2D {
                while !(tag.count >= 5 && tag[tag.count - 3] == 0x2D && tag[tag.count - 2] == 0x2D && tag[tag.count - 1] == 0x3E) {
                    if !r.readUntil(0x3E, &tag) { break }
                }
                continue
            }
            if tag.last == 0x3E { tag.removeLast() }
            let closing = tag.first == 0x2F
            var ns = closing ? 1 : 0
            while closing && ns < tag.count && tag[ns] == 0x20 { ns += 1 }
            var ne = ns
            while ne < tag.count && !(tag[ne] == 0x20 || tag[ne] == 0x09 || tag[ne] == 0x0A || tag[ne] == 0x0D || tag[ne] == 0x2F) { ne += 1 }
            let name = tag[ns..<ne]
            if want != 0 && closing {
                let s = xmlUnescape(String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                if want == 1 && bytesEqual(name, "display-name") {
                    if let id = chan, (alias[id] ?? "").isEmpty {
                        let n = norm(s)
                        if tids.contains(id) {
                            alias[id] = id
                        } else if !n.isEmpty && keys.contains(n) {
                            alias[id] = "n:\(n)"
                        } else {
                            alias[id] = ""
                        }
                    }
                } else if want == 2 && bytesEqual(name, "title") && title == nil {
                    title = s
                }
                want = 0
                continue
            }
            if closing {
                if bytesEqual(name, "channel") {
                    chan = nil
                } else if bytesEqual(name, "programme") {
                    if let p = prog {
                        let t = (title?.isEmpty == false) ? title! : "(không tên)"
                        out[p.key, default: []].append(IptvProgramme(s: p.s, e: p.e ?? p.s + 1800, t: t))
                    }
                    prog = nil
                    title = nil
                }
                continue
            }
            if bytesEqual(name, "channel") {
                chan = xmlAttr(tag, "id")
            } else if bytesEqual(name, "display-name") && chan != nil {
                want = 1
            } else if bytesEqual(name, "programme") {
                prog = nil
                title = nil
                guard let cid = xmlAttr(tag, "channel") else { continue }
                let key: String
                if let k = alias[cid] {
                    key = k
                } else {
                    key = tids.contains(cid) ? cid : ""
                    alias[cid] = key
                }
                guard !key.isEmpty, let s = xmlAttr(tag, "start").flatMap(xmltvTime) else { continue }
                let e = xmlAttr(tag, "stop").flatMap(xmltvTime)
                let ok = s <= to && (e.map { $0 >= from } ?? (s >= from))
                if ok { prog = (key, s, e) }
            } else if bytesEqual(name, "title") && prog != nil && title == nil {
                want = 2
            }
        }
        for k in out.keys { out[k]?.sort { $0.s < $1.s } }
        return out
    }
}

/// Một chương trình trong lịch phát sóng.
struct IptvProgramme: Codable, Equatable {
    var s: Double
    var e: Double
    var t: String
}
