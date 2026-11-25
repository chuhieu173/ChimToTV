import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit

// Trình phát truyền hình / radio (IPTV) bản iPad / iPhone / Mac — AVPlayer: HLS, đài MP3 / AAC (Icecast, kèm tên bài ICY), Referer /
// User-Agent riêng của nguồn. Cùng cách chạy với tivi (LiveActivity.kt), Windows (LiveView.cs) và Linux (live.rs): nguồn lỗi tự
// sang nguồn sau; hỏng hết nguồn thì tải lại danh sách (cũ quá 10 phút) tìm link mới một lần; trận sắp / đang đá mà chưa có hình thì
// chờ, tải lại danh sách, thử lại mỗi 20 giây; link giả «no-signal» / hình chờ ngắn không phát; đài radio hiện thẻ đài.
// AVPlayer không phát được HTTP-FLV → nguồn FLV ghi «máy không phát được», sang nguồn sau.
// Phím: ▲ ▼ / PgUp PgDn đổi kênh, Enter hiện nút, ◀ / M bảng kênh (phim: ◀ ▶ tua), số 0–9 gõ số kênh, Space tạm dừng, G lịch, Esc.

/// Đọc tên bài ICY / ID3 của đài (AVPlayerItemMetadataOutput).
private final class IcyReader: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    var onTitle: (String) -> Void = { _ in }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        for g in groups {
            for item in g.items where item.identifier == .icyMetadataStreamTitle || item.commonKey == .commonKeyTitle {
                if let s = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { onTitle(s) }
            }
        }
    }
}

@MainActor
final class LiveModel: NSObject, ObservableObject, LimitHost {
    static weak var current: LiveModel?

    struct StatusBox: Equatable {
        var text: String
        var spinner: Bool
        var retry: String?
    }

    let player = AVPlayer()
    @Published private(set) var ch: IptvChannelView?
    private(set) var filter: IptvFilter
    @Published private(set) var index: Int
    @Published private(set) var total = 0
    @Published private(set) var source = 0
    @Published private(set) var started = false
    @Published private(set) var paused = false
    @Published private(set) var waiting = false
    @Published private(set) var radio = false
    @Published private(set) var icy: String?
    @Published private(set) var radioDesc: String?
    @Published private(set) var status: StatusBox?
    @Published private(set) var controls = true
    @Published private(set) var panelShown = false
    @Published private(set) var panelItems: [IptvChannelView] = []
    @Published private(set) var panelFrom = 0
    @Published private(set) var notice: String?
    @Published private(set) var clock = ""
    @Published private(set) var delay: Double = 0
    @Published private(set) var limitBlock: WatchLimit.Block?
    @Published private(set) var vodTime: (t: Double, d: Double) = (0, 0)
    /// Đổi mỗi 15 giây: vẽ lại chương trình đang phát / tiến độ
    @Published private(set) var minuteTick = 0

    var onClose: (() -> Void)?

    private var token = 0
    private var startedAt: Int64 = 0
    private var openedAt: Int64 = 0
    private var reopens = 0
    private var listChecked = false
    private var pausedAt: Int64 = 0
    private var limitWarned = false
    private var limitResume: (() -> Void)?
    private var digits = ""
    private var waitingRetry = false
    private var errorShown = false
    private var failed: String?
    private var ended = false
    private var ticks = 0
    private var closed = false
    private var poller: Task<Void, Never>?
    private var timers: [String: Task<Void, Never>] = [:]
    private var itemObservers: [NSObjectProtocol] = []
    private let icyReader = IcyReader()

    init(filter: IptvFilter, index: Int) {
        self.filter = filter
        self.index = index
        super.init()
        icyReader.onTitle = { [weak self] t in
            guard let me = self else { return }
            Task { @MainActor in me.gotIcy(t) }
        }
        player.automaticallyWaitsToMinimizeStalling = true
        // Đang nối CarPlay: không phát ra «màn ngoài» (màn xe) — không thì lớp hình trong app đen (UI/CarScreen.swift)
        if CarScreen.shared.connected { player.allowsExternalPlayback = false }
    }

    // MARK: - Mở / đóng

    func begin() {
        LiveModel.current = self
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self = self, !Task.isCancelled else { return }
                self.tick()
            }
        }
        playAt(index)
    }

    /// Đổi sang kênh khác (đang mở trình phát: nhắc giờ phát, lịch…).
    func open(_ filter: IptvFilter, _ index: Int) {
        self.filter = filter
        panelShown = false
        playAt(index)
    }

    func close() {
        guard !closed else { return }
        closed = true
        teardown()
        onClose?()
    }

    func teardown() {
        token += 1
        poller?.cancel()
        poller = nil
        for t in timers.values { t.cancel() }
        timers.removeAll()
        stopPlayer()
        WatchLimit.flush()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if LiveModel.current === self { LiveModel.current = nil }
    }

    private func stopPlayer() {
        for o in itemObservers { NotificationCenter.default.removeObserver(o) }
        itemObservers.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func after(_ key: String, _ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        timers[key]?.cancel()
        timers[key] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            body()
        }
    }

    private var urls: [IptvSource] { ch?.urls ?? [] }

    private func firstUsable(_ u: [IptvSource]) -> Int {
        var src = 0
        while src + 1 < u.count && u[src].bad != nil { src += 1 }
        return src
    }

    func playAt(_ i: Int) {
        token += 1
        let t = token
        started = false
        stopPlayer()
        showLoading("Đang mở kênh…")
        let f = filter
        Task {
            let c = await Iptv.at(f, i)
            guard t == token, !closed else { return }
            guard let c = c else {
                showError("Danh sách không còn kênh này.", retry: false)
                return
            }
            index = i
            total = c.total
            ch = c
            listChecked = false
            reopens = 0
            source = firstUsable(c.urls)
            openSource()
            if panelShown { buildPanel() }
        }
    }

    func step(_ delta: Int) {
        guard total >= 2 else { return }
        playAt(((index + delta) % total + total) % total)
        bumpHide()
    }

    func nextSource() {
        let n = urls.count
        guard n >= 2 else { return }
        source = (source + 1) % n
        reopens = 0
        openSource()
    }

    private func openSource() {
        token += 1
        let t = token
        guard limitBlock == nil else { return } // màn «Hết giờ xem» đang hiện: không mở luồng nào
        started = false
        icy = nil
        radioDesc = nil
        delay = 0
        pausedAt = 0
        waitingRetry = false
        errorShown = false
        failed = nil
        ended = false
        paused = false
        stopPlayer()
        guard let c = ch else { return }
        setRadio(c.radio)
        guard source < c.urls.count else {
            showError("\(c.n) không có địa chỉ phát.", retry: false)
            return
        }
        let src = c.urls[source]
        if let bad = src.bad {
            sourceFailed(bad, permanent: true, t)
            return
        }
        if IptvParse.isPlaceholder(src.url) {
            sourceFailed("Danh sách chưa có link phát (đang để hình «không có tín hiệu»).", permanent: false, t)
            return
        }
        if IptvParse.isFlv(src.url) {
            let why = "Máy này không phát được luồng HTTP-FLV."
            Iptv.markBad(src.url, why)
            sourceFailed(why, permanent: true, t)
            return
        }
        guard let url = URL(string: src.url) ?? URL(string: src.url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
        else {
            sourceFailed("Địa chỉ phát không hợp lệ.", permanent: true, t)
            return
        }
        showLoading("Đang mở \(c.n)…")
        Log.d("tv", "\(c.n) (nguồn \(source + 1)/\(c.urls.count)) \(src.url)")
        openedAt = nowMs()
        var headers: [String: String] = [:]
        if let r = src.referer { headers["Referer"] = r }
        if let u = src.ua { headers["User-Agent"] = u }
        let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        let out = AVPlayerItemMetadataOutput(identifiers: nil)
        out.setDelegate(icyReader, queue: .main)
        item.add(out)
        let nc = NotificationCenter.default
        itemObservers.append(nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] n in
            let why = (n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "luồng bị ngắt"
            guard let me = self else { return }
            Task { @MainActor in me.failed = why }
        })
        itemObservers.append(nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let me = self else { return }
            Task { @MainActor in me.ended = true }
        })
        player.replaceCurrentItem(with: item)
        player.play()
    }

    // MARK: - Hai lần mỗi giây

    private func tick() {
        guard !closed else { return }
        ticks += 1
        let item = player.currentItem
        let tc = player.timeControlStatus
        let isPlaying = tc == .playing
        paused = started && tc == .paused
        waiting = tc == .waitingToPlayAtSpecifiedRate
        if ticks % 2 == 0 {
            WatchLimit.tick(playing: started && isPlaying)
            if checkLimit() { return }
        }
        if let c = ch, !waitingRetry, !errorShown, limitBlock == nil {
            if !started {
                if let it = item, it.status == .failed {
                    itemFailed(it.error)
                } else if let f = failed {
                    sourceFailed("Không mở được luồng (\(f)).", permanent: false, token)
                } else if let it = item, it.status == .readyToPlay, isPlaying || it.currentTime().seconds > 0.3 {
                    onStarted(it)
                } else if nowMs() - openedAt > 25_000 {
                    sourceFailed("Máy chủ của kênh không trả lời (quá 25 giây).", permanent: false, token)
                }
            } else if let it = item, it.status == .failed || failed != nil {
                Log.d("tv", "lỗi khi đang phát: \(it.error?.localizedDescription ?? failed ?? "")")
                reopenLater("đứt")
            } else if ended {
                if c.vod {
                    showError("Đã xem hết \(c.n).", retry: true, label: "Xem lại")
                } else {
                    reopenLater("hết")
                }
            }
        }
        if started {
            if isPlaying && reopens > 0 && nowMs() - startedAt > 60_000 { reopens = 0 }
            radioTick()
            if ch?.vod == true, let it = item {
                let d = it.duration.seconds
                vodTime = (it.currentTime().seconds, d.isFinite ? d : 0)
            }
        }
        if ticks % 2 == 0 {
            clock = (waiting ? "Đang tải…  " : "") + IptvParse.clock(Iptv.nowSec())
            if ticks % 30 == 0 { minuteTick += 1 }
        }
    }

    /// AVPlayer báo lỗi trước khi phát: định dạng máy không giải mã được → ghi «không phát được» (ẩn kênh hỏng hết nguồn).
    private func itemFailed(_ error: Error?) {
        let ns = error as NSError?
        // AVFoundationErrorDomain: không nhận ra định dạng, không đọc được tệp, thiếu bộ giải mã, giải mã hỏng, dữ liệu không giải mã được
        let codes = [-11828, -11829, -11833, -11821, -11853, -11855]
        let what = ns?.localizedDescription ?? "lỗi lạ"
        if let e = ns, e.domain == AVFoundationErrorDomain, codes.contains(e.code), let u = urls[safe: source]?.url {
            let why = "Máy này không giải mã được luồng (\(what))."
            Iptv.markBad(u, why)
            sourceFailed(why, permanent: true, token)
        } else {
            sourceFailed("Không mở được luồng (\(what)).", permanent: false, token)
        }
    }

    private func onStarted(_ item: AVPlayerItem) {
        guard let c = ch else { return }
        // Danh sách phát là đoạn phim ngắn có hồi kết (hình chờ «không có tín hiệu») — AVPlayer báo độ dài hữu hạn
        let d = item.duration.seconds
        if !c.vod && d.isFinite && d > 0 && d < 120 {
            sourceFailed("Kênh đang phát hình chờ (đoạn phim ngắn), chưa có luồng trực tiếp.", permanent: false, token)
            return
        }
        started = true
        startedAt = nowMs()
        listChecked = false
        hideStatus()
        let k = c.k
        Task { await Iptv.played(k) }
        Log.d("tv", "\(c.n) đang phát (nguồn \(source + 1))")
        setControls(true)
        updateNowPlaying()
    }

    private func reopenLater(_ why: String) {
        reopens += 1
        started = false
        Log.d("tv", "luồng \(ch?.n ?? "") \(why) — mở lại lần \(reopens)")
        if reopens > 5 {
            sourceFailed("Luồng liên tục bị đứt.", permanent: false, token)
            return
        }
        // Bỏ luồng hỏng ngay (lỗi cũ không bị nhịp kiểm tra sau hiểu thành «không mở được»), chờ 1 giây rồi mở lại
        token += 1
        let t = token
        stopPlayer()
        failed = nil
        ended = false
        openedAt = nowMs()
        showLoading("Đang nối lại…")
        after("reopen", 1) { [weak self] in
            guard let self = self, self.token == t, !self.closed else { return }
            self.openSource()
        }
    }

    private func sourceFailed(_ reason: String, permanent: Bool, _ t: Int) {
        guard token == t, !closed, let c = ch else { return }
        stopPlayer()
        let u = urls
        if Iptv.autoSource && source + 1 < u.count {
            Log.d("tv", "\(c.n) nguồn \(source + 1) lỗi (\(reason)) — sang nguồn \(source + 2)")
            source += 1
            reopens = 0
            openSource()
            return
        }
        let now = Iptv.nowSec()
        let usable = u.contains { $0.bad == nil }
        if usable && [.later, .soon, .live].contains(c.match) {
            let msg = now < c.kick
                ? "Trận chưa bắt đầu — bóng lăn lúc \(IptvParse.kickText(c.kick, now: now)).\nKênh chưa lên sóng, tự thử lại sau 20 giây…"
                : "Trận đang đá nhưng kênh chưa phát hình.\nTự thử lại sau 20 giây…"
            Log.d("tv", "\(c.n) chưa có hình (\(reason)) — chờ 20 s")
            showError(msg, retry: true)
            waitingRetry = true
            after("wait", 20) { [weak self] in
                guard let self = self, self.token == t, !self.closed, !self.started else { return }
                self.refreshChannel(age: 120) { _ in self.retryFromFirst() }
            }
            return
        }
        let text = "\(c.n) không phát được.\n\(reason)"
        if !permanent && !listChecked && c.match == .none && Iptv.activeList()?.url != nil {
            listChecked = true
            showLoading("Đang kiểm tra link mới…")
            refreshChannel(age: 600) { [weak self] changed in
                guard let self = self else { return }
                if changed {
                    self.retryFromFirst()
                } else if self.token == t {
                    self.showError(text, retry: true)
                }
            }
            return
        }
        showError(text, retry: !permanent)
    }

    /// Tải lại danh sách nếu cũ hơn `age` giây, lấy bản mới của kênh đang xem (cùng khoá). done(true) = nguồn vừa đổi.
    private func refreshChannel(age: Int64, _ done: @escaping (Bool) -> Void) {
        let f = filter
        guard let key = ch?.k else { return done(false) }
        let t = token
        Task {
            try? await Iptv.refreshIfOlder(than: age)
            // Trong lúc tải lại danh sách (vài giây) người xem đã sang kênh khác / đóng trình phát: bỏ kết quả, không thì kênh
            // cũ đè lên kênh đang xem và bị phát lại
            guard t == token, !closed else { return }
            let i = await Iptv.indexOf(f, key: key)
            guard t == token, !closed else { return }
            guard i >= 0, let fresh = await Iptv.at(f, i), t == token, !closed else { return done(false) }
            let before = urls.map { $0.url }
            index = i
            ch = fresh
            total = fresh.total
            done(before != fresh.urls.map { $0.url })
        }
    }

    private func retryFromFirst() {
        source = firstUsable(urls)
        reopens = 0
        openSource()
    }

    func retry() {
        guard let c = ch else {
            playAt(index)
            return
        }
        if c.vod && status?.text.hasPrefix("Đã xem hết") == true {
            openSource()
            return
        }
        showLoading("Đang kiểm tra link mới…")
        if c.kick > 0 {
            refreshChannel(age: 120) { [weak self] _ in self?.retryFromFirst() }
            return
        }
        if Iptv.activeList()?.url == nil {
            reopens = 0
            openSource()
            return
        }
        refreshChannel(age: 600) { [weak self] changed in
            guard let self = self else { return }
            if changed {
                self.retryFromFirst()
            } else {
                self.reopens = 0
                self.openSource()
            }
        }
    }

    // MARK: - Phát / dừng

    func togglePlay() {
        guard started else {
            reopens = 0
            openSource()
            return
        }
        let vod = ch?.vod == true
        if player.timeControlStatus != .paused {
            player.pause()
            pausedAt = nowMs()
        } else {
            if radio && !vod {
                openSource()
                return
            }
            if pausedAt > 0 && !vod { delay += Double(nowMs() - pausedAt) / 1000 }
            pausedAt = 0
            player.play()
        }
        paused = player.timeControlStatus == .paused || player.rate == 0
        bumpHide()
    }

    func goLive() {
        reopens = 0
        openSource()
    }

    func seek(_ by: Double) {
        guard started, ch?.vod == true, let it = player.currentItem else { return }
        let d = it.duration.seconds
        guard d.isFinite, d > 0 else { return }
        let to = min(max(0, it.currentTime().seconds + by), d)
        player.seek(to: CMTime(seconds: to, preferredTimescale: 600))
        setControls(true)
    }

    var badge: String {
        let vod = ch?.vod == true
        if vod { return !started ? "PHIM" : paused ? "TẠM DỪNG" : "▶ PHIM" }
        if !started { return "CHƯA PHÁT" }
        if paused { return "TẠM DỪNG" }
        if delay > 8 { return "CHẬM \(formatTime(delay))" }
        return "● TRỰC TIẾP"
    }

    var liveButton: Bool { started && ch?.vod != true && (delay > 8 || paused) }

    // MARK: - Nhãn

    var programmes: (now: IptvProgramme?, next: IptvProgramme?) {
        let now = Iptv.nowSec()
        let all = ch?.programmes ?? []
        return (all.first { $0.s <= now && now < $0.e }, all.first { $0.s > now })
    }

    /// Dòng thời gian + tiến độ (−1 = không có) dưới tên chương trình.
    var timeLine: (text: String, frac: Double) {
        guard let c = ch else { return ("", -1) }
        let now = Iptv.nowSec()
        if c.vod && started && vodTime.d > 0 {
            return ("\(formatTime(vodTime.t)) / \(formatTime(vodTime.d)) · ◀ ▶ tua 10 giây", vodTime.t / vodTime.d)
        }
        if let p = programmes.now {
            return ("\(IptvParse.clock(p.s))–\(IptvParse.clock(p.e)) · còn \(max(1, Int(((p.e - now) / 60).rounded(.up)))) phút",
                    (now - p.s) / max(1, p.e - p.s))
        }
        if let ml = c.matchLine {
            return ("\(c.g) · \(ml)", c.match == .live ? (now - c.kick) / (Double(c.dur) * 60) : -1)
        }
        return (radio ? "\(c.g) · đài phát thanh" : "\(c.g) · chưa có lịch phát sóng", -1)
    }

    // MARK: - Radio

    private func setRadio(_ on: Bool) {
        if on && !radio { setControls(true) }
        radio = on
        if on { updateNowPlaying() }
    }

    private func gotIcy(_ t: String) {
        guard radio || ch?.radio == true, t != icy else { return }
        Log.d("tv", "\(ch?.n ?? "") đang phát «\(t)»")
        icy = t
        updateNowPlaying()
    }

    /// Luồng không có hình (đài HLS như VOV, Icecast) → kiểu radio; có hình trở lại thì thôi. Mã tiếng / kbps của đài.
    private func radioTick() {
        guard let c = ch, let item = player.currentItem else { return }
        let hasVideo = item.presentationSize.width > 0 || item.tracks.contains { $0.assetTrack?.mediaType == .video }
        let want = !hasVideo && !c.vod && (c.radio || nowMs() - startedAt > 4000)
        if want != radio {
            Log.d("tv", "\(c.n) \(want ? "chỉ có tiếng — hiện kiểu đài radio" : "có hình — thôi kiểu radio")")
            setRadio(want)
        }
        guard radio else { return }
        var codec: String?
        var kbps = 0
        for t in item.tracks {
            guard let a = t.assetTrack, a.mediaType == .audio else { continue }
            if let fd = a.formatDescriptions.first {
                switch CMFormatDescriptionGetMediaSubType(fd as! CMFormatDescription) {
                case kAudioFormatMPEGLayer3: codec = "MP3"
                case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: codec = "AAC"
                case kAudioFormatAC3: codec = "AC-3"
                default: break
                }
            }
            if a.estimatedDataRate > 0 { kbps = Int(a.estimatedDataRate / 1000) }
        }
        if kbps == 0, let ev = item.accessLog()?.events.last, ev.indicatedBitrate > 0 { kbps = Int(ev.indicatedBitrate / 1000) }
        let parts = [codec, kbps > 0 ? "\(kbps) kbps" : nil].compactMap { $0 }
        let desc = parts.isEmpty ? nil : parts.joined(separator: " · ")
        if desc != radioDesc { radioDesc = desc }
    }

    /// Màn khoá / Trung tâm điều khiển: tên đài + bài đang phát (radio phát tiếp khi tắt màn hình).
    private func updateNowPlaying() {
        guard let c = ch else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: icy ?? programmes.now?.t ?? c.n, MPMediaItemPropertyArtist: c.n,
                                   MPNowPlayingInfoPropertyIsLiveStream: !c.vod]
        if icy != nil || programmes.now != nil { info[MPMediaItemPropertyAlbumTitle] = c.n }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Trạng thái

    private func showLoading(_ text: String) {
        status = StatusBox(text: text, spinner: true, retry: nil)
        errorShown = false
    }

    private func showError(_ text: String, retry: Bool, label: String = "Thử lại") {
        Log.d("tv", text.replacingOccurrences(of: "\n", with: " "))
        status = StatusBox(text: text, spinner: false, retry: retry ? label : nil)
        errorShown = true
        controls = true
        timers["hide"]?.cancel()
    }

    private func hideStatus() {
        status = nil
        errorShown = false
    }

    func showNotice(_ text: String, _ seconds: Double) {
        notice = text
        after("notice", seconds) { [weak self] in self?.notice = nil }
    }

    // MARK: - Nút / bảng kênh

    func setControls(_ on: Bool) {
        controls = on
        bumpHide()
    }

    func tapped() {
        if panelShown {
            hidePanel()
        } else {
            setControls(!controls || !started)
        }
    }

    func bumpHide() {
        timers["hide"]?.cancel()
        guard controls || panelShown else { return }
        after("hide", panelShown ? 10 : 6) { [weak self] in self?.autoHide() }
    }

    /// Không bấm gì một lúc khi đang phát: ẩn nút và bảng kênh. Radio: giữ nút.
    private func autoHide() {
        guard started, !paused, !errorShown else { return }
        panelShown = false
        if !radio { controls = false }
    }

    func togglePanel() {
        if panelShown {
            hidePanel()
            return
        }
        panelShown = true
        buildPanel()
        bumpHide()
    }

    func hidePanel() {
        panelShown = false
        setControls(true)
    }

    /// Bảng kênh: 100 kênh quanh kênh đang xem (danh sách lớn).
    func buildPanel(around: Int? = nil) {
        let from = max(0, (around ?? index) - 40)
        let f = filter
        Task {
            let page = await Iptv.page(f, offset: from, limit: 100)
            panelFrom = from
            panelItems = page.items
            total = page.total
        }
    }

    func panelPick(_ c: IptvChannelView) {
        if c.index != index { playAt(c.index) }
        bumpHide()
    }

    func toggleFavorite() {
        guard var c = ch else { return }
        c.fav.toggle()
        Iptv.setFavorite(c.k, c.fav)
        ch = c
        showNotice(c.fav ? "Đã thêm \(c.n) vào Yêu thích." : "Đã bỏ \(c.n) khỏi Yêu thích.", 4)
        bumpHide()
    }

    var hasGuide: Bool { !(ch?.programmes.isEmpty ?? true) }

    func openGuide() {
        let (f, i) = (filter, index)
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Router.tvGuide(f, i) }
    }

    // MARK: - Gõ số kênh

    func typeDigit(_ d: Int) {
        if digits.count >= 5 { digits = "" }
        digits += String(d)
        showNotice("Kênh số \(digits)_", 1.6)
        after("digits", 1.5) { [weak self] in self?.jumpToNumber() }
    }

    private func jumpToNumber() {
        var n = String(digits.drop { $0 == "0" })
        digits = ""
        if n.isEmpty { n = "0" }
        let f = filter
        Task {
            let i = await Iptv.indexOf(f, num: n)
            if i >= 0 {
                playAt(i)
            } else {
                showNotice("Không có kênh số \(n) trong danh sách đang xem.", 4)
            }
        }
    }

    // MARK: - Giới hạn giờ xem

    private func checkLimit() -> Bool {
        guard limitBlock == nil else { return true }
        if let b = WatchLimit.block() {
            Log.d("tv", "hết giờ xem (\(b))")
            // Huỷ mọi việc đang chờ (mở lại sau 1 giây, thử lại trận sau 20 giây, tải lại danh sách): không thì luồng tự phát
            // lại sau màn «Hết giờ xem»
            token += 1
            for t in timers.values { t.cancel() }
            timers.removeAll()
            stopPlayer()
            started = false
            limitBlock = b
            let (f, i) = (filter, index)
            limitResume = { [weak self] in self?.open(f, i) }
            return true
        }
        if started, !limitWarned, let r = WatchLimit.remaining(), r > 0, r <= 300 {
            limitWarned = true
            showNotice("Còn \(WatchLimit.minutesText(r)) xem hôm nay (\(Prefs.profile.name)).", 8)
        }
        return false
    }

    func grantLimit(_ minutes: Int?) {
        if let m = minutes { WatchLimit.grant(m) } else { WatchLimit.grantUntilMorning() }
        limitBlock = nil
        limitWarned = false
        let resume = limitResume
        limitResume = nil
        resume?()
    }

    var limitText: String {
        let who = Prefs.profile.name
        switch limitBlock {
        case .bedtime: return "Đã tới giờ đi ngủ của \(who) (từ \(WatchLimit.bedtimeLabel(Prefs.bedtime())) tới 6 giờ sáng)."
        case .daily: return "\(who) đã xem hết \(WatchLimit.dailyLabel(Prefs.dailyLimit())) của hôm nay."
        case nil: return ""
        }
    }

    // MARK: - Phím

    /// Esc / Back: đóng bảng / nút rồi mới thoát.
    func escape() {
        if panelShown {
            hidePanel()
        } else if controls && started && status == nil {
            controls = false
        } else {
            close()
        }
    }

    /// Phím mũi tên khi đang ẩn nút / bảng: ▲ ▼ đổi kênh, ◀ bảng kênh (phim: tua), ▶ hiện nút.
    func arrow(_ d: KeyNav.Dir) {
        bumpHide()
        let vod = ch?.vod == true
        switch d {
        case .up: step(-1)
        case .down: step(1)
        case .left: if vod { seek(-10) } else { togglePanel() }
        case .right: if vod { seek(10) } else { setControls(true) }
        }
    }

    /// Cổng gỡ lỗi.
    func debugState() -> [String: Any] {
        let item = player.currentItem
        let w = Int(item?.presentationSize.width ?? 0)
        let h = Int(item?.presentationSize.height ?? 0)
        var o: [String: Any] = ["num": ch?.num ?? "", "name": ch?.n ?? "", "index": index, "total": total]
        o["source"] = source
        o["sources"] = urls.count
        o["url"] = urls[safe: source]?.url ?? ""
        o["started"] = started
        o["badge"] = badge
        o["status"] = status?.text ?? ""
        o["timeControl"] = player.timeControlStatus.rawValue
        o["itemStatus"] = item?.status.rawValue ?? -1
        o["error"] = item?.error?.localizedDescription ?? ""
        o["size"] = "\(w)x\(h)"
        o["radio"] = radio
        o["icy"] = icy ?? ""
        o["radioDesc"] = radioDesc ?? ""
        o["controls"] = controls
        o["panel"] = panelShown
        o["limit"] = limitBlock.map { "\($0)" } ?? ""
        o["delay"] = delay
        return o
    }
}


// MARK: - Giao diện

/// Lớp hình AVPlayerLayer.
private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ v: PlayerLayerView, context: Context) {}
}


/// Màn xem truyền hình — cùng kiểu với trình phát phim (PlayerView): thanh trên / dưới phủ gradient, nút tròn, bảng kênh trượt
/// từ phải, thẻ đài radio trên nền logo làm mờ.
struct LiveView: View {
    @ObservedObject var m: LiveModel
    @Environment(\.horizontalSizeClass) private var hClass

    private var compact: Bool { hClass == .compact }
    fileprivate static let red = Color(hex: 0xE5533D)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if m.radio { radioBackdrop }
            VideoSurface(player: m.player).ignoresSafeArea().opacity(m.radio ? 0 : 1)
            // Chạm: hiện / ẩn nút; vuốt dọc: đổi kênh (vuốt lên = kênh sau)
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { m.tapped() }
                .gesture(DragGesture(minimumDistance: 40).onEnded { v in
                    let dy = v.translation.height, dx = v.translation.width
                    guard abs(dy) > 80, abs(dy) > abs(dx) * 1.5 else { return }
                    m.step(dy < 0 ? 1 : -1)
                })
            if m.radio && m.status == nil { radioCard.allowsHitTesting(false) }
            if m.controls && m.limitBlock == nil {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    bottomBar
                }
                .transition(.opacity)
            }
            if let s = m.status { statusOverlay(s) }
            if m.panelShown { panel.transition(.move(edge: .trailing)) }
            VStack {
                if let n = m.notice {
                    Text(n)
                        .appFont(17, .medium)
                        .multilineTextAlignment(.center)
                        .foregroundColor(Theme.text)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.78)))
                        .padding(.top, m.controls ? (compact ? 76 : 96) : 24)
                        .padding(.horizontal, 40)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                Spacer()
            }
        }
        .overlay {
            if m.limitBlock != nil { LimitOverlay(m: m) }
        }
        .animation(.easeOut(duration: 0.18), value: m.controls)
        .animation(.easeOut(duration: 0.22), value: m.panelShown)
        .animation(.easeOut(duration: 0.2), value: m.notice)
        .preferredColorScheme(.dark)
        .appDynamicType()
    }

    // MARK: Thanh trên: thoát, tên kênh, nhãn trực tiếp, giờ

    private var badgeColor: Color {
        let b = m.badge
        if b.hasPrefix("●") { return Self.red }
        if b.hasPrefix("CHẬM") { return Theme.focus }
        if b.contains("PHIM") { return Color(hex: 0x8B5CF6) }
        return Theme.surface2
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            RoundButton(icon: "xmark", label: "Thoát", compact: compact) { m.close() }
            VStack(alignment: .leading, spacing: 2) {
                Text(m.ch?.n ?? "").appFont(compact ? 17 : 20, .semibold).foregroundColor(Theme.text).lineLimit(1)
                if let c = m.ch {
                    Text("Kênh \(c.num) · \(c.g)\(c.urls.count > 1 ? " · nguồn \(m.source + 1)/\(c.urls.count)" : "")")
                        .appFont(13).foregroundColor(Theme.dim).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(m.badge)
                .appFont(12, .bold)
                .foregroundColor(badgeColor == Theme.focus ? Theme.onBrand : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(badgeColor))
                .fixedSize()
            if !compact {
                Text(m.clock).appFont(15, .medium, mono: true).foregroundColor(Theme.text.opacity(0.85)).fixedSize()
            }
        }
        .padding(.horizontal, compact ? 12 : 20)
        .padding(.top, compact ? 8 : 14)
        .padding(.bottom, compact ? 18 : 34)
        .background(LinearGradient(colors: [Color.black.opacity(0.78), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    // MARK: Thanh dưới: chương trình đang phát, tiến độ, nút

    private var bottomBar: some View {
        let tl = m.timeLine
        let (now, next) = m.programmes
        let playing = m.started && !m.paused
        // Radio không có lịch: thẻ đài giữa màn đã có tên + bài đang phát → bỏ dòng thông tin lặp lại
        let infoRow = !(m.radio && now == nil && m.status == nil)
        return VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            if infoRow {
                HStack(alignment: .center, spacing: 14) {
                    if !compact {
                        LogoTile(url: m.ch?.logo, radio: m.radio, corner: 10).frame(width: 78, height: 50)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(now?.t ?? m.icy ?? m.ch?.n ?? "").appFont(compact ? 16 : 19, .semibold).foregroundColor(Theme.text).lineLimit(1)
                        Text(tl.text).appFont(13).foregroundColor(Theme.dim).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let n = next, !compact {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("TIẾP THEO · \(IptvParse.clock(n.s))").appFont(11, .bold).foregroundColor(Theme.dim)
                            Text(n.t).appFont(14, .medium).foregroundColor(Theme.text.opacity(0.85)).lineLimit(1)
                        }
                        .frame(maxWidth: 280, alignment: .trailing)
                    }
                }
            }
            if tl.frac >= 0 {
                ProgressView(value: min(1, max(0, tl.frac)))
                    .tint(m.ch?.match == .live ? Self.red : Theme.brand)
            }
            HStack(spacing: compact ? 10 : 12) {
                RoundButton(icon: "list.bullet", label: "Danh sách kênh", compact: compact) { m.togglePanel() }
                RoundButton(icon: "chevron.up", label: "Kênh trước", compact: compact) { m.step(-1) }
                RoundButton(icon: playing ? "pause.fill" : "play.fill", label: playing ? "Tạm dừng" : "Phát", big: true,
                            compact: compact) { m.togglePlay() }
                RoundButton(icon: "chevron.down", label: "Kênh sau", compact: compact) { m.step(1) }
                if m.ch?.vod == true && m.started && !compact {
                    RoundButton(icon: "gobackward.10", label: "Lùi 10 giây") { m.seek(-10) }
                    RoundButton(icon: "goforward.10", label: "Tới 10 giây") { m.seek(10) }
                }
                Spacer(minLength: 0)
                if m.liveButton {
                    pill("Về trực tiếp", icon: "dot.radiowaves.left.and.right", tint: Self.red) { m.goLive() }
                }
                if (m.ch?.urls.count ?? 0) > 1 && !compact {
                    pill("Nguồn \(m.source + 1)/\(m.ch?.urls.count ?? 0)", icon: "arrow.triangle.2.circlepath", tint: nil) { m.nextSource() }
                }
                if m.hasGuide {
                    RoundButton(icon: "calendar", label: "Lịch phát sóng", compact: compact) { m.openGuide() }
                }
                RoundButton(icon: m.ch?.fav == true ? "star.fill" : "star", label: m.ch?.fav == true ? "Bỏ yêu thích" : "Yêu thích",
                            compact: compact) { m.toggleFavorite() }
            }
        }
        .padding(.horizontal, compact ? 14 : 24)
        .padding(.top, compact ? 24 : 44)
        .padding(.bottom, compact ? 10 : 22)
        .background(LinearGradient(colors: [.clear, Color.black.opacity(0.88)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .id(m.minuteTick)
    }

    private func pill(_ text: String, icon: String, tint: Color?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).appFont(15, .semibold)
                Text(text).appFont(15, .semibold).lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .frame(height: compact ? 44 : 50)
            .background(Capsule().fill(tint ?? Color.white.opacity(0.14)))
        }
        .buttonStyle(PressScale())
        .hoverEffect(.highlight)
    }

    // MARK: Radio: nền logo làm mờ + thẻ đài

    private var radioBackdrop: some View {
        ZStack {
            LogoTile(url: m.ch?.logo, radio: true, corner: 0)
                .scaleEffect(1.6)
                .blur(radius: 60)
                .opacity(0.55)
            LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var radioCard: some View {
        GeometryReader { geo in
            // iPhone ngang chỉ cao ~400 pt: thẻ nhỏ lại để không chạm thanh nút
            let short = geo.size.height < 500
            let side: CGFloat = short ? 92 : (compact ? 130 : 200)
            let name = m.ch?.n ?? ""
            VStack(spacing: short ? 8 : (compact ? 10 : 16)) {
                LogoTile(url: m.ch?.logo, radio: true, corner: short ? 18 : (compact ? 22 : 32))
                    .frame(width: side, height: side)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                Text(name).appFont(short ? 20 : (compact ? 24 : 32), .bold).foregroundColor(Theme.text)
                    .multilineTextAlignment(.center).lineLimit(2)
                if let s = radioSong {
                    Label(s, systemImage: "music.note")
                        .appFont(short ? 15 : (compact ? 16 : 20), .medium)
                        .foregroundColor(Theme.text.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .lineLimit(short ? 1 : 2)
                }
                Label(m.radioDesc.map { "Radio · \($0)" } ?? "Radio", systemImage: "radio")
                    .appFont(13, .semibold)
                    .foregroundColor(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .padding(.horizontal, 40)
            .frame(width: geo.size.width, height: geo.size.height)
            .offset(y: m.controls ? (short ? -24 : (compact ? -30 : -50)) : 0)
        }
    }

    /// Bài đang phát (ICY) hoặc chương trình theo lịch — bỏ khi chỉ là tên đài lặp lại
    private var radioSong: String? {
        guard let s = m.icy ?? m.programmes.now?.t, !s.isEmpty else { return nil }
        let name = m.ch?.n ?? ""
        return s.caseInsensitiveCompare(name) == .orderedSame ? nil : s
    }

    // MARK: Đang mở / lỗi

    private func statusOverlay(_ s: LiveModel.StatusBox) -> some View {
        ZStack {
            Color.black.opacity(m.radio ? 0.3 : 0.55).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 18) {
                if s.spinner {
                    ProgressView().scaleEffect(1.5).tint(Theme.text)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash").appFont(40, .light).foregroundColor(Theme.dim)
                }
                Text(s.text)
                    .appFont(compact ? 17 : 20, .medium)
                    .foregroundColor(Theme.text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                if !s.spinner {
                    HStack(spacing: 10) {
                        if let r = s.retry {
                            ChipButton(text: r, icon: "arrow.clockwise", active: true) { m.retry() }.frame(width: 150)
                        }
                        ChipButton(text: "Kênh sau", icon: "chevron.down") { m.step(1) }.frame(width: 140)
                        ChipButton(text: "Quay lại", icon: "xmark") { m.close() }.frame(width: 140)
                    }
                }
            }
            .padding(.horizontal, 30)
        }
    }

    // MARK: Bảng kênh (trượt từ phải, như menu của trình phát phim)

    private var panel: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Color.black.opacity(0.3)
                    .contentShape(Rectangle())
                    .onTapGesture { m.hidePanel() }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Danh sách kênh").appFont(19, .semibold).foregroundColor(Theme.text)
                            Text("\(Iptv.activeList()?.name ?? "") · \(m.total) kênh").appFont(13).foregroundColor(Theme.dim).lineLimit(1)
                        }
                        Spacer()
                        Button { m.hidePanel() } label: {
                            Image(systemName: "xmark.circle.fill").appFont(28).foregroundColor(Theme.dim)
                        }
                        .accessibilityLabel("Đóng danh sách kênh")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                if m.panelFrom > 0 {
                                    ChipButton(text: "Kênh trước nữa", icon: "chevron.up") { m.buildPanel(around: max(0, m.panelFrom - 60)) }
                                }
                                ForEach(m.panelItems) { c in panelRow(c).id(c.index) }
                                if m.panelFrom + 100 < m.total {
                                    ChipButton(text: "Kênh sau nữa", icon: "chevron.down") {
                                        m.buildPanel(around: min(m.panelFrom + 140, max(0, m.total - 1)))
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 18)
                        }
                        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo(m.index, anchor: .center) } }
                        .onChange(of: m.panelItems.first?.index) { _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(m.index, anchor: .center) }
                        }
                    }
                }
                .frame(width: min(430, geo.size.width * 0.92))
                .background(Theme.surface.opacity(0.97).ignoresSafeArea())
            }
        }
    }

    private func panelRow(_ c: IptvChannelView) -> some View {
        let cur = c.index == m.index
        let sub = c.bad != nil ? "Máy này không phát được" : c.now?.t ?? c.matchLine ?? c.g
        return Button { m.panelPick(c) } label: {
            HStack(spacing: 12) {
                LogoTile(url: c.logo, radio: c.radio, corner: 8).frame(width: 60, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(c.num).appFont(12, .bold, mono: true).opacity(0.7)
                        Text(c.n).appFont(16, .semibold).lineLimit(1)
                    }
                    Text(sub).appFont(13).opacity(0.75).lineLimit(1)
                }
                Spacer(minLength: 0)
                if cur {
                    Image(systemName: "speaker.wave.2.fill").appFont(14)
                } else if c.fav {
                    Image(systemName: "star.fill").appFont(12).foregroundColor(Theme.focus)
                }
            }
            .foregroundColor(cur ? Theme.onBrand : Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(cur ? Theme.brand : Theme.surface2.opacity(0.7)))
            .opacity(c.bad != nil ? 0.55 : 1)
        }
        .buttonStyle(PressScale())
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 12))
        .hoverEffect(.highlight)
    }
}

final class LiveController: UIHostingController<LiveView> {
    let model: LiveModel

    init(model: LiveModel) {
        self.model = model
        super.init(rootView: LiveView(m: model))
        modalPresentationStyle = .fullScreen
        view.backgroundColor = .black
    }

    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) { fatalError("không dùng") }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone && !CarScreen.shared.uiOnCar ? .landscape : .all
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        UIDevice.current.userInterfaceIdiom == .phone && !CarScreen.shared.uiOnCar
            ? .landscapeRight : super.preferredInterfaceOrientationForPresentation
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.onClose = { [weak self] in
            self?.dismiss(animated: true)
            AppModel.shared.refreshTvHome() // trang chủ: hàng «Kênh vừa xem» / tiến độ chương trình
        }
        model.begin()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            UIApplication.shared.isIdleTimerDisabled = CarScreen.keepPhoneAwake // đang nối xe: màn điện thoại đừng tự khoá
            model.teardown()
            TvModel.shared.loadCards()
        }
    }

    /// Phím tắt; có tên thì hiện trong bảng phím tắt của iPad (giữ phím ⌘).
    private static let keys: [(input: String, title: String?)] = [
        (UIKeyCommand.inputUpArrow, "Kênh trước"), (UIKeyCommand.inputPageUp, nil),
        (UIKeyCommand.inputDownArrow, "Kênh sau"), (UIKeyCommand.inputPageDown, nil),
        (UIKeyCommand.inputLeftArrow, "Bảng kênh (phim: lùi 10 giây)"),
        (UIKeyCommand.inputRightArrow, "Hiện nút (phim: tới 10 giây)"),
        (" ", "Tạm dừng / phát"), ("\r", "Hiện / ẩn nút"), ("m", "Bảng kênh"), ("g", "Lịch phát sóng"), ("s", "Đổi nguồn"),
        ("f", "Thêm / bỏ Yêu thích"), (UIKeyCommand.inputEscape, "Thoát"),
    ] + (0...9).map { (String($0), $0 == 0 ? "Số 0–9: gõ số kênh" : nil) }

    override var keyCommands: [UIKeyCommand]? {
        var list = Self.keys.map { k -> UIKeyCommand in
            let c = UIKeyCommand(input: k.input, modifierFlags: [], action: #selector(key(_:)))
            if let t = k.title {
                c.title = t
                c.discoverabilityTitle = t
            }
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
        let close = UIKeyCommand(input: "w", modifierFlags: .command, action: #selector(closeKey))
        close.title = "Thoát trình phát"
        close.discoverabilityTitle = "Thoát trình phát"
        list.append(close)
        return list
    }

    @objc private func closeKey() { model.close() }

    @objc private func key(_ c: UIKeyCommand) {
        guard let input = c.input else { return }
        if model.limitBlock != nil {
            if input == UIKeyCommand.inputEscape { model.close() }
            return
        }
        model.bumpHide()
        switch input {
        case UIKeyCommand.inputUpArrow, UIKeyCommand.inputPageUp: model.arrow(.up)
        case UIKeyCommand.inputDownArrow, UIKeyCommand.inputPageDown: model.arrow(.down)
        case UIKeyCommand.inputLeftArrow: model.arrow(.left)
        case UIKeyCommand.inputRightArrow: model.arrow(.right)
        case " ": model.togglePlay()
        case "\r": model.tapped()
        case "m": model.togglePanel()
        case "g": if model.hasGuide { model.openGuide() }
        case "s": model.nextSource()
        case "f": model.toggleFavorite()
        case UIKeyCommand.inputEscape: model.escape()
        default:
            if let d = Int(input), (0...9).contains(d) { model.typeDigit(d) }
        }
    }
}
