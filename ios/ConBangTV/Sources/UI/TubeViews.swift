import SwiftUI
import UIKit

// Mục «TubeMini» của menu (ngay dưới «Truyền hình · Radio»): xem YouTube qua máy chủ tubemini-server trong nhà — lõi ở
// Core/TubeMini.swift. Chip Đã theo dõi / Phổ biến / chủ đề / Lịch sử / Kênh / Tìm, lưới thẻ video 16:9, trang kênh. Chạm thẻ là
// phát (danh sách đang xem thành «tập» của trình phát: video kế / tự sang video sau). Hồ sơ trẻ em không có mục này (anh chọn
// 25/11/2026: máy chủ không lọc nội dung trẻ em); giới hạn giờ xem tính cả TubeMini (trình phát phim tự đếm).

@MainActor
final class TubeModel: ObservableObject {
    static let shared = TubeModel()

    enum Tab: Hashable {
        case feed, popular(String), history, channels, search, channel(String, String)
    }

    static let chips: [(String, Tab)] = [
        ("Đã theo dõi", .feed), ("Phổ biến", .popular("")), ("Âm nhạc", .popular("Music")), ("Tin tức", .popular("News")),
        ("Thể thao", .popular("Sports")), ("Trò chơi", .popular("Games")), ("Phim", .popular("Film")),
        ("Lịch sử", .history), ("Kênh", .channels),
    ]
    // Tìm: ô tìm (kính lúp) nằm ngay trên hàng tiêu đề «TubeMini» — anh chọn 25/11/2026, nhìn là hiểu (trước là chip «Tìm»)

    @Published private(set) var tab: Tab = .feed
    @Published private(set) var videos: [TubeVideo] = []
    @Published private(set) var channels: [TubeChannel] = []
    @Published private(set) var status: String?
    @Published private(set) var loading = false
    @Published var query = ""
    @Published private(set) var subscribed = Set<String>()
    @Published private(set) var serverNote = ""
    @Published private(set) var configured = TubeMini.configured
    private var next: String?
    private var token = 0
    private var started = false

    /// Tên danh sách (tiêu đề phim giả của trình phát).
    var tabTitle: String {
        switch tab {
        case .feed: return "Đã theo dõi"
        case .popular(let c): return Self.chips.first { $0.1 == .popular(c) }?.0 ?? "Phổ biến"
        case .history: return "Lịch sử"
        case .channels: return "Kênh đã theo dõi"
        case .search: return query.isEmpty ? "Tìm" : "Tìm: \(query)"
        case .channel(_, let name): return name
        }
    }

    /// Chọn mục TubeMini trong menu.
    func appear() {
        configured = TubeMini.configured
        guard configured else { return }
        if !started {
            started = true
            loadSubscribed()
            reload()
        }
    }

    func open(_ t: Tab) {
        tab = t
        if t == .search && query.trimmed.isEmpty {
            token += 1
            videos = []
            channels = []
            next = nil
            loading = false
            status = "Gõ tên video / kênh rồi nhấn Tìm."
            return
        }
        reload()
    }

    func search(_ q: String) {
        query = q
        tab = .search
        reload()
    }

    func reload(fresh: Bool = false) {
        token += 1
        let t = token
        videos = []
        channels = []
        next = nil
        status = nil
        loading = true
        let tab = self.tab, q = query.trimmed
        Task {
            do {
                var page = TubePage()
                switch tab {
                case .feed:
                    page = try await TubeMini.feed(fresh: fresh)
                    if page.videos.isEmpty { status = "Chưa theo dõi kênh nào — mở «Phổ biến» / «Tìm», giữ ngón tay trên một video → «Theo dõi kênh»." }
                case .popular(let c): page = try await TubeMini.popular(c)
                case .history:
                    page = try await TubeMini.history()
                    if page.videos.isEmpty { status = "Chưa xem video nào." }
                case .channels:
                    page.channels = try await TubeMini.subscriptions()
                    subscribed = Set(page.channels.map(\.id))
                    if page.channels.isEmpty { status = "Chưa theo dõi kênh nào." }
                case .search:
                    async let v = TubeMini.search(q)
                    async let c = TubeMini.searchChannels(q)
                    page = try await v
                    page.channels = Array(((try? await c) ?? []).prefix(6))
                    if page.videos.isEmpty && page.channels.isEmpty { status = "Không thấy video nào cho «\(q)»." }
                case .channel(let id, _): page = try await TubeMini.uploads(id)
                }
                guard t == token else { return }
                videos = page.videos
                channels = page.channels
                next = page.next
            } catch {
                guard t == token else { return }
                status = error.localizedDescription
            }
            if t == token { loading = false }
        }
    }

    var hasMore: Bool { next != nil }

    func loadMore() {
        guard let n = next, !loading else { return }
        next = nil
        loading = true
        let t = token
        Task {
            do {
                let p = try await TubeMini.page(n)
                guard t == token else { return }
                let have = Set(videos.map(\.id))
                videos += p.videos.filter { !have.contains($0.id) }
                next = p.next
            } catch {
                guard t == token else { return }
                AppModel.shared.showToast(error.localizedDescription)
            }
            if t == token { loading = false }
        }
    }

    func play(_ v: TubeVideo, audio: Bool = false) {
        guard let i = videos.firstIndex(of: v) else { return }
        Router.playTube(videos, at: i, title: "TubeMini · \(tabTitle)", audio: audio)
    }

    func openChannel(_ id: String, _ name: String) {
        guard !id.isEmpty else { return }
        open(.channel(id, name.isEmpty ? "Kênh" : name))
    }

    func loadSubscribed() {
        Task {
            if let list = try? await TubeMini.subscriptions() { subscribed = Set(list.map(\.id)) }
        }
    }

    func toggleSubscribe(_ id: String, _ name: String) {
        guard !id.isEmpty else { return }
        let on = subscribed.contains(id)
        Task {
            do {
                if on { try await TubeMini.unsubscribe(id) } else { try await TubeMini.subscribe(id) }
                if on { subscribed.remove(id) } else { subscribed.insert(id) }
                AppModel.shared.showToast(on ? "Đã bỏ theo dõi \(name)." : "Đã theo dõi \(name) — video mới ở «Đã theo dõi».")
                if tab == .channels || tab == .feed { reload(fresh: true) }
            } catch {
                AppModel.shared.showToast(error.localizedDescription)
            }
        }
    }

    func removeFromHistory(_ v: TubeVideo) {
        Task {
            do {
                try await TubeMini.deleteHistory(v.id)
                videos.removeAll { $0.id == v.id }
            } catch {
                AppModel.shared.showToast(error.localizedDescription)
            }
        }
    }

    /// Lưu địa chỉ máy chủ, thử kết nối; được thì tải lại.
    func setServer(_ address: String, token tk: String) {
        TubeMini.server = address
        TubeMini.token = tk
        configured = TubeMini.configured
        serverNote = configured ? "Đang kiểm tra…" : ""
        guard configured else { return }
        Task {
            do {
                serverNote = "Đã kết nối: " + (try await TubeMini.ping())
                started = true
                loadSubscribed()
                reload()
            } catch {
                serverNote = "Không kết nối được: \(error.localizedDescription)"
            }
        }
    }

    /// Hộp sửa địa chỉ máy chủ / mã (nút ⚙︎).
    func editServer() {
        TvAlert.show("Máy chủ TubeMini", "Địa chỉ tubemini-server trong nhà (vd 192.168.1.10:8080). Mã (token) chỉ cần khi máy chủ có bật "
                     + "auth_token.", ["Lưu", "Huỷ"],
                     fields: [(TubeMini.server, "địa chỉ:cổng"), (TubeMini.token, "mã (token) — để trống nếu không có")]) { [weak self] i, texts in
            guard i == 0 else { return }
            self?.setServer(texts[safe: 0] ?? "", token: texts[safe: 1] ?? "")
        }
    }
}

extension Router {
    /// Phát video TubeMini: cả danh sách đang xem thành các «tập» (video kế / trước, tự sang video sau).
    static func playTube(_ videos: [TubeVideo], at i: Int, title: String, audio: Bool = false) {
        guard let v = videos[safe: i] else { return }
        let list = TubeMini.makeQueue(title: title, videos: videos, audioOnly: audio)
        play(filmUrl: list, epUrl: TubeMini.videoUrl(v.id))
    }
}

// MARK: - Trang TubeMini

struct TubeContent: View {
    @ObservedObject var m = TubeModel.shared
    @EnvironmentObject var app: AppModel
    @ObservedObject private var scale = TextScale.shared
    let showMenuButton: Bool
    let openMenu: () -> Void
    @FocusState private var searchFocused: Bool
    @State private var address = TubeMini.server
    @State private var token = TubeMini.token
    /// Thanh trên (tiêu đề + ô tìm + chip) đang khuất: cuộn xuống thì ẩn, cuộn lên / về đầu thì hiện — như menu nổi của Roza
    /// (RZTabs: quá 80 điểm, mỗi lần cuộn hơn 12 điểm). Thanh nằm đè lên danh sách nên ẩn / hiện không làm danh sách nhảy.
    @State private var barsHidden = false
    @State private var topH: CGFloat = 120
    @State private var track = ScrollTrack()

    final class ScrollTrack {
        var lastY: CGFloat = 0
        var travel: CGFloat = 0
    }

    var body: some View {
        Group {
            if m.configured {
                ZStack(alignment: .top) {
                    grid
                    topBar
                        .background(GeometryReader { g in Color.clear.preference(key: TubeTopHeight.self, value: g.size.height) })
                        .background(Theme.bg.ignoresSafeArea(edges: .top))
                        .offset(y: barsHidden ? -topH - 8 : 0)
                        .animation(.easeOut(duration: 0.22), value: barsHidden)
                }
                .onPreferenceChange(TubeTopHeight.self) { topH = $0 }
                .clipped()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    setup
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { m.appear() }
        .onChange(of: app.historyVersion) { _ in if m.tab == .history { m.reload() } } // vừa đóng trình phát
        .onChange(of: m.tab) { _ in barsHidden = false }
        .onChange(of: searchFocused) { f in if f { barsHidden = false } }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            chips
            if case .channel(let id, let name) = m.tab { channelBar(id, name) }
        }
    }

    /// Vị trí cuộn mới (điểm, 0 = đầu danh sách).
    private func scrolled(_ y: CGFloat) {
        let t = track
        let d = y - t.lastY
        t.lastY = y
        if y <= 10 {
            t.travel = 0
            if barsHidden { barsHidden = false }
            return
        }
        if d == 0 { return }
        if (d > 0) != (t.travel > 0) { t.travel = 0 }
        t.travel += d
        if t.travel > 12 && y > 80 && !barsHidden && !searchFocused {
            barsHidden = true
        } else if t.travel < -12 && barsHidden {
            barsHidden = false
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if showMenuButton {
                Button(action: openMenu) {
                    Image(systemName: "line.3.horizontal").appFont(22, .semibold).foregroundColor(Theme.text).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Menu")
            }
            Text("TubeMini").appFont(26, .bold).foregroundColor(Theme.text).lineLimit(1).fixedSize()
            if m.loading { ProgressView().tint(Theme.dim) }
            if m.configured {
                searchField
                Button { m.reload(fresh: true) } label: {
                    Image(systemName: "arrow.clockwise").appFont(18, .semibold).foregroundColor(Theme.text).frame(width: 36, height: 40)
                }
                .accessibilityLabel("Tải lại")
                Button { m.editServer() } label: {
                    Image(systemName: "gearshape").appFont(18, .semibold).foregroundColor(Theme.text).frame(width: 36, height: 40)
                }
                .accessibilityLabel("Máy chủ TubeMini")
            } else {
                Spacer(minLength: 8)
            }
        }
        .padding(.leading, showMenuButton ? 8 : 20)
        .padding(.trailing, 10)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// Ô tìm cạnh tiêu đề: kính lúp (chạm = tìm), chữ mờ «Tìm video, kênh», nút ✕ xoá chữ.
    private var searchField: some View {
        HStack(spacing: 8) {
            Button {
                if m.query.trimmed.isEmpty { searchFocused = true } else { runSearch() }
            } label: {
                Image(systemName: "magnifyingglass").appFont(17, .semibold).foregroundColor(Theme.dim)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tìm")
            TextField("Tìm video, kênh", text: $m.query)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { runSearch() }
                .carSubmit(searchFocused) { m.search(m.query) } // bàn phím riêng của màn xe
                .disableAutocorrection(true)
                .foregroundColor(Theme.text)
            if !m.query.isEmpty {
                Button { m.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Theme.dim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Xoá chữ tìm")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Capsule().fill(Theme.surface2))
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func runSearch() {
        guard !m.query.trimmed.isEmpty else { return }
        m.search(m.query)
        CarKeyboard.shared.hide()
        searchFocused = false
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TubeModel.chips.indices, id: \.self) { i in
                    let c = TubeModel.chips[i]
                    let on = c.1 == m.tab
                    Button { m.open(c.1) } label: {
                        Text(c.0)
                            .appFont(15, on ? .semibold : .regular)
                            .foregroundColor(on ? Theme.onBrand : Theme.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(on ? Theme.brand : Theme.surface2))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
    }

    private func channelBar(_ id: String, _ name: String) -> some View {
        let on = m.subscribed.contains(id)
        return HStack(spacing: 12) {
            Text(name).appFont(20, .bold).foregroundColor(Theme.text).lineLimit(1)
            Spacer(minLength: 8)
            Button(on ? "Đã theo dõi" : "Theo dõi") { m.toggleSubscribe(id, name) }
                .buttonStyle(.borderedProminent)
                .tint(on ? Theme.surface2 : Theme.brand)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var grid: some View {
        GeometryReader { geo in
            let pad: CGFloat = geo.size.width < 500 ? 14 : 20
            let minW = min(scale.layout(geo.size.width < 600 ? 220 : 270), max(160, geo.size.width - pad * 2))
            ScrollView {
                // Một lưới lười duy nhất (kênh là tiêu đề mục, trạng thái / trang sau là chân mục) — như trang Truyền hình
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minW), spacing: 14)], alignment: .leading, spacing: 18) {
                    Section {
                        ForEach(m.videos) { v in TubeCard(v: v, m: m) }
                    } header: {
                        if !m.channels.isEmpty { channelList }
                    } footer: {
                        footer
                    }
                }
                .padding(.horizontal, pad)
                .padding(.bottom, 8)
                .padding(.top, topH + 8) // chừa chỗ cho thanh trên (nằm đè lên danh sách)
                .background(ScrollWatch { y in scrolled(y) })
            }
        }
    }

    private var channelList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(m.channels) { c in
                let on = m.subscribed.contains(c.id)
                HStack(spacing: 12) {
                    Button { m.openChannel(c.id, c.name) } label: {
                        HStack(spacing: 12) {
                            PosterImage(url: c.avatar, maxPixel: 120)
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).appFont(16, .semibold).foregroundColor(Theme.text).lineLimit(1)
                                if let s = c.subscribers, s > 0 {
                                    Text("\(TubeMini.countText(s)) người đăng ký").appFont(13).foregroundColor(Theme.dim)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button(on ? "Đã theo dõi" : "Theo dõi") { m.toggleSubscribe(c.id, c.name) }
                        .buttonStyle(.bordered)
                        .tint(on ? Theme.dim : Theme.brand)
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let s = m.status {
                Text(s).appFont(15).foregroundColor(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 20)
            }
            if m.hasMore {
                ProgressView().tint(Theme.text).frame(maxWidth: .infinity).padding(20).onAppear { m.loadMore() }
            }
        }
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Xem YouTube qua máy chủ TubeMini")
                    .appFont(20, .bold).foregroundColor(Theme.text)
                Text("TubeMini cần máy chủ tubemini-server chạy trong nhà (dự án TubeMini — yt-dlp lấy link, video tải thẳng từ YouTube). "
                     + "Nhập địa chỉ máy chủ, ví dụ 192.168.1.10:8080. Kênh theo dõi và lịch sử lưu trên máy chủ, dùng chung với app TubeMini.")
                    .appFont(15).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
                field("Địa chỉ máy chủ (máy:cổng)", text: $address)
                field("Mã (token) — để trống nếu máy chủ không bật", text: $token)
                Button("Lưu và kiểm tra") { m.setServer(address, token: token) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .controlSize(.large)
                if !m.serverNote.isEmpty {
                    Text(m.serverNote).appFont(14).foregroundColor(Theme.dim)
                }
            }
            .padding(20)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    private func field(_ hint: String, text: Binding<String>) -> some View {
        TextField(hint, text: text)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .foregroundColor(Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
    }
}

private struct TubeTopHeight: PreferenceKey {
    static var defaultValue: CGFloat = 120
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Báo vị trí cuộn (điểm từ đầu nội dung) của khung cuộn chứa view này — gắn làm nền của nội dung ScrollView (SwiftUI của iOS 15
/// chưa có cách đọc vị trí cuộn; theo dõi contentOffset của UIScrollView bên dưới).
struct ScrollWatch: UIViewRepresentable {
    let changed: (CGFloat) -> Void

    final class Probe: UIView {
        var changed: (CGFloat) -> Void = { _ in }
        private var obs: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            obs = nil
            guard window != nil else { return }
            var v = superview
            while let s = v, !(s is UIScrollView) { v = s.superview }
            guard let sv = v as? UIScrollView else { return }
            obs = sv.observe(\.contentOffset, options: [.new]) { [weak self] s, _ in
                let y = s.contentOffset.y + s.adjustedContentInset.top
                DispatchQueue.main.async { self?.changed(y) }
            }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let p = Probe()
        p.isUserInteractionEnabled = false
        p.changed = changed
        return p
    }

    func updateUIView(_ p: Probe, context: Context) { p.changed = changed }
}

/// Thẻ video: ảnh 16:9 (thời lượng, vạch đã xem), tên, «kênh · lượt xem · thời gian». Giữ ngón tay: chỉ nghe, kênh, theo dõi.
private struct TubeCard: View {
    let v: TubeVideo
    @ObservedObject var m: TubeModel

    var body: some View {
        Button { m.play(v) } label: {
            VStack(alignment: .leading, spacing: 6) {
                PosterImage(url: v.thumb, maxPixel: 480)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(alignment: .bottomTrailing) {
                        if v.duration > 0 {
                            Text(TubeMini.durationText(v.duration))
                                .appFont(12, .semibold, mono: true)
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.75)))
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let p = v.position, p > 0, v.duration > 0 {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Color.white.opacity(0.35))
                                    Rectangle().fill(Color.red).frame(width: g.size.width * min(1, CGFloat(p) / CGFloat(v.duration)))
                                }
                            }
                            .frame(height: 3)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(v.title).appFont(15, .semibold).foregroundColor(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                Text(TubeMini.metaText(v)).appFont(13).foregroundColor(Theme.dim).lineLimit(2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(v.title)
        .contextMenu {
            Button { m.play(v, audio: true) } label: { Label("Chỉ nghe", systemImage: "headphones") }
            if !v.authorId.isEmpty {
                Button { m.openChannel(v.authorId, v.author) } label: { Label("Mở kênh \(v.author)", systemImage: "person.crop.square") }
                let on = m.subscribed.contains(v.authorId)
                Button { m.toggleSubscribe(v.authorId, v.author) } label: {
                    Label(on ? "Bỏ theo dõi kênh" : "Theo dõi kênh", systemImage: on ? "bell.slash" : "bell")
                }
            }
            if m.tab == .history {
                Button(role: .destructive) { m.removeFromHistory(v) } label: { Label("Xoá khỏi lịch sử", systemImage: "trash") }
            }
        }
    }
}
