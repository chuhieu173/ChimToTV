import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Truyền hình · Radio (IPTV): danh sách kênh M3U người xem tự thêm (app không kèm sẵn kênh) — kênh vừa xem, nhóm, tìm tên / số kênh,
// ★ yêu thích, chương trình đang phát, trạng thái trận; lịch phát sóng; cài đặt. Một mục của menu bên trái như Trang chủ / Lịch sử
// (khung chính, cùng kiểu thẻ / dải vuốt / phím tắt với lưới phim). Lõi: Core/Iptv.swift; trình phát: Player/LivePlayer.swift.
// Bản Windows: UI/TvPages.cs; Linux: pages/tv.rs; tivi: TvActivity.kt.

// MARK: - Mở màn / phát kênh

extension Router {
    /// Chọn mục «Truyền hình · Radio» của menu.
    static func tv(then: (() -> Void)? = nil) {
        let app = AppModel.shared
        // Đừng đóng màn miễn trừ / «Ai đang xem?» (chúng cũng là màn được trình bày đè lên)
        guard !app.gateUp else { return }
        if let top = topController, top.presentingViewController != nil, !(top is LiveController) {
            top.dismiss(animated: true)
        }
        if app.sheet != nil { app.sheet = nil }
        if app.active?.kind != .tv, let e = app.menu.first(where: { $0.kind == .tv }) { app.select(e) }
        app.detailFilm = nil
        if let t = then { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { t() } }
    }

    /// Phát kênh ở vị trí `index` của bộ lọc. Trình phát truyền hình đang mở thì đổi kênh; phim đang phát thì đóng phim trước.
    static func playLive(_ filter: IptvFilter, _ index: Int) {
        if let cur = LiveModel.current {
            cur.open(filter, index)
            return
        }
        guard !AppModel.shared.gateUp else { return }
        PlayerModel.detachedModel?.closeDetached()
        guard let top = topController else { return }
        if let p = top as? PlayerController {
            p.model.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { playLive(filter, index) }
            return
        }
        top.present(LiveController(model: LiveModel(filter: filter, index: index)), animated: true)
    }

    /// Mở kênh theo khoá (nhắc giờ phát / kênh vừa xem) trong cả danh sách đang chọn.
    static func playLiveKey(_ key: String) {
        Task { @MainActor in
            let i = await Iptv.indexOf(IptvFilter(), key: key)
            if i < 0 {
                AppModel.shared.showToast("Danh sách kênh đang chọn không có kênh này.")
            } else {
                playLive(IptvFilter(), i)
            }
        }
    }

    /// Lịch phát sóng của kênh (từ trình phát / menu ô kênh).
    static func tvGuide(_ filter: IptvFilter, _ index: Int) {
        tv { TvModel.shared.guideTarget = TvGuideTarget(filter: filter, index: index) }
    }
}

/// Hộp hỏi / báo trong cửa sổ riêng nằm trên mọi thứ (bảng SwiftUI, trình phát…) — như AppModel.askUpdate.
@MainActor
enum TvAlert {
    private static var window: UIWindow?

    /// `fields`: ô nhập (giá trị đầu, chữ mờ); `done(nút, chữ trong các ô)`. Nút cuối là nút huỷ khi có từ hai nút.
    static func show(_ title: String, _ message: String?, _ buttons: [String], fields: [(String, String)] = [],
                     done: @escaping (Int, [String]) -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        window?.isHidden = true
        let main = scene.windows.first { $0.isKeyWindow } ?? scene.windows.first
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert
        w.backgroundColor = .clear
        w.overrideUserInterfaceStyle = .dark
        let host = UIViewController()
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        for (value, hint) in fields {
            a.addTextField { t in
                t.text = value
                t.placeholder = hint
                t.clearButtonMode = .whileEditing
                t.autocorrectionType = .no
            }
        }
        for (i, b) in buttons.enumerated() {
            let cancel = buttons.count > 1 && i == buttons.count - 1
            a.addAction(UIAlertAction(title: b, style: cancel ? .cancel : .default) { [weak a] _ in
                let texts = a?.textFields?.map { $0.text ?? "" } ?? []
                w.isHidden = true
                if window === w { window = nil }
                if main?.isKeyWindow == false { main?.makeKey() }
                done(i, texts)
            })
        }
        if let first = a.actions.first, buttons.count > 1 { a.preferredAction = first }
        DispatchQueue.main.async { host.present(a, animated: true) }
    }

    static func show(_ title: String, _ message: String?, _ buttons: [String], done: @escaping (Int) -> Void) {
        show(title, message, buttons, fields: [], done: { i, _ in done(i) })
    }
}

struct TvGuideTarget: Identifiable, Equatable {
    let filter: IptvFilter
    let index: Int
    var id: String { "\(filter.hashValue)-\(index)" }
}

// MARK: - Mô hình màn kênh

@MainActor
final class TvModel: ObservableObject {
    static let shared = TvModel()
    static let pageSize = 150

    @Published var filter = IptvFilter()
    @Published private(set) var groups = IptvGroups()
    @Published private(set) var items: [IptvChannelView] = []
    @Published private(set) var total = 0
    @Published private(set) var offset = 0
    @Published private(set) var info = ""
    @Published private(set) var hasList = Iptv.activeList() != nil
    @Published private(set) var lists: [IptvList] = []
    @Published private(set) var activeId: String?
    @Published private(set) var recent: [IptvRecent] = []
    @Published private(set) var busy = false
    @Published var search = ""
    @Published var addShown = false
    @Published var guideTarget: TvGuideTarget?
    @Published var settingsShown = false
    @Published private(set) var now = Iptv.nowSec()
    /// Ô đang chọn bằng bàn phím (khoá kênh)
    /// Theo `IptvChannelView.id` (số thứ tự, duy nhất) — không theo khoá kênh `k`: một kênh có thể nằm ở nhiều nhóm nên
    /// trong «Tất cả» hai ô trùng `k`
    @Published var keySel: Int?
    var cols = 3

    private var version: UInt64 = .max
    private var favsChosen = false
    private var ticker: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var loadToken = 0
    private var profile = Prefs.profileId

    func start() {
        // Đổi người xem: yêu thích / vừa xem của người mới
        if profile != Prefs.profileId {
            profile = Prefs.profileId
            favsChosen = false
            filter = IptvFilter(group: nil, favs: false, q: filter.q)
        }
        version = .max
        rebuild()
        if Iptv.activeList() != nil { refreshList(force: false) }
        ticker?.cancel()
        ticker = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self, !Task.isCancelled else { return }
                ticks += 1
                self.tick(ticks)
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    /// Mỗi giây: đang tải danh sách / lịch thì cập nhật dòng trạng thái; dữ liệu đổi thì dựng lại. Mỗi 30 giây: vẽ lại giờ trận /
    /// chương trình, tự làm mới danh sách khi quá hạn.
    private func tick(_ ticks: Int) {
        let st = Iptv.status()
        busy = st.loading || st.guideLoading
        if st.version != version {
            rebuild()
        } else {
            updateInfo(st)
        }
        if ticks % 30 == 0 {
            loadCards()
            Task { await Iptv.autoRefresh() }
        }
    }

    func toast(_ text: String) { AppModel.shared.showToast(text) }

    private func updateInfo(_ st: IptvStatus) {
        guard let l = st.active else {
            info = ""
            return
        }
        var t = l.name
        if let s = st.status {
            t += " · \(s)"
        } else {
            if l.count > 0 { t += " · \(l.count) kênh" }
            if l.updated > 0 { t += " · cập nhật \(IptvParse.clock(Double(l.updated) / 1000))" }
            if Prefs.kids { t += " · hồ sơ trẻ em: kênh thiếu nhi" }
        }
        info = t
    }

    func rebuild() {
        let st = Iptv.status()
        version = st.version
        busy = st.loading || st.guideLoading
        hasList = st.active != nil
        lists = Iptv.lists()
        activeId = st.active?.id
        recent = Iptv.recent()
        updateInfo(st)
        guard hasList else {
            groups = IptvGroups()
            items = []
            total = 0
            return
        }
        Task {
            let g = await Iptv.groups()
            if !favsChosen && g.total > 0 {
                favsChosen = true
                if g.favs > 0 { filter = IptvFilter(group: nil, favs: true, q: filter.q) }
            }
            // Nhóm đang chọn không còn (đổi danh sách / hồ sơ trẻ em): về «Tất cả»
            if let gid = filter.group, !g.groups.contains(where: { $0.id == gid }) { filter.group = nil }
            if filter.favs && g.favs == 0 && g.total > 0 { filter.favs = false }
            groups = g
            loadCards()
        }
    }

    func loadCards() {
        loadToken += 1
        let t = loadToken
        let f = filter
        let off = offset
        Task {
            let page = await Iptv.page(f, offset: off, limit: Self.pageSize)
            guard t == loadToken else { return }
            now = Iptv.nowSec()
            total = page.total
            items = page.items
            if let k = keySel, !page.items.contains(where: { $0.id == k }) { keySel = nil }
        }
    }

    /// Tên mục đang xem (tiêu đề trên lưới).
    var sectionTitle: String {
        if !filter.q.isEmpty { return "Kết quả cho «\(filter.q)»" }
        if filter.favs { return "Yêu thích" }
        if let g = filter.group, let x = groups.groups.first(where: { $0.id == g }) { return x.name }
        return "Tất cả kênh"
    }

    func choose(group: Int?, favs: Bool) {
        filter.group = group
        filter.favs = favs
        offset = 0
        keySel = nil
        loadCards()
    }

    func searchChanged(_ q: String) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self = self, !Task.isCancelled else { return }
            self.filter.q = q.trimmingCharacters(in: .whitespaces)
            self.offset = 0
            self.loadCards()
        }
    }

    func page(_ delta: Int) {
        offset = max(0, min(offset + delta * Self.pageSize, max(0, total - 1)))
        keySel = nil
        loadCards()
    }

    func refreshList(force: Bool) {
        busy = true
        Task {
            do {
                try await Iptv.refresh(force: force)
                if force { toast("Đã tải lại danh sách kênh.") }
            } catch {
                toast(friendly(error))
            }
            rebuild()
        }
    }

    func useList(_ id: String) {
        guard id != activeId else { return }
        Iptv.setActive(id)
        favsChosen = false
        filter = IptvFilter()
        search = ""
        offset = 0
        keySel = nil
        rebuild()
        refreshList(force: false)
    }

    func open(_ c: IptvChannelView) {
        keySel = c.id
        let f = filter
        if c.match == .later {
            let m = Int(((c.kick - Iptv.nowSec()) / 60).rounded(.up))
            let left = m >= 24 * 60 ? "\((m + 720) / 1440) ngày" : m >= 60 ? "\(m / 60) giờ \(String(format: "%02d", m % 60)) phút" : "\(m) phút"
            let has = Iptv.hasReminder(key: c.k, kick: true)
            TvAlert.show("Trận chưa bắt đầu",
                         "\(c.n)\nBóng lăn lúc \(IptvParse.kickText(c.kick, now: Iptv.nowSec())) (còn \(left)).\n" +
                            "Kênh trận đấu thường chỉ lên sóng trước giờ đá 15–30 phút.",
                         [has ? "Bỏ nhắc" : "Nhắc lúc bóng lăn", "Vẫn mở", "Đóng"]) { [weak self] r in
                if r == 0 { self?.toggleKick(c) }
                if r == 1 { Router.playLive(f, c.index) }
            }
            return
        }
        Router.playLive(f, c.index)
    }

    /// Kênh vừa xem: kênh của danh sách khác thì đổi sang danh sách đó.
    func openRecent(_ r: IptvRecent) {
        if let l = r.l, l != activeId, Iptv.lists().contains(where: { $0.id == l }) { useList(l) }
        Router.playLiveKey(r.k)
    }

    func toggleKick(_ c: IptvChannelView) {
        let on = Iptv.toggleReminder(key: c.k, name: c.n, title: c.n, s: c.kick, kick: true)
        toast(on ? "Sẽ nhắc lúc bóng lăn (\(IptvParse.kickText(c.kick, now: Iptv.nowSec()))) — khi app đang mở." : "Đã bỏ nhắc.")
        loadCards()
    }

    func toggleFavorite(_ c: IptvChannelView) {
        Iptv.setFavorite(c.k, !c.fav)
        toast(c.fav ? "Đã bỏ \(c.n) khỏi Yêu thích." : "Đã thêm \(c.n) vào Yêu thích.")
    }

    func retry(_ c: IptvChannelView) {
        Iptv.clearBad(forKey: c.k)
        open(c)
    }

    /// Thêm danh sách theo địa chỉ / từ tệp rồi tải.
    func added(_ l: IptvList, text: String? = nil) {
        toast(text ?? "Đã thêm danh sách «\(l.name)» — đang tải kênh…")
        favsChosen = false
        filter = IptvFilter()
        search = ""
        offset = 0
        busy = true
        rebuild()
        Task {
            do {
                try await Iptv.refresh(force: true)
            } catch {
                toast(friendly(error))
            }
            rebuild()
        }
    }

    var emptyText: String {
        if !filter.q.isEmpty { return "Không có kênh nào khớp «\(filter.q)»." }
        if filter.favs { return "Chưa có kênh yêu thích — giữ tay (hoặc nhấn chuột phải) trên ô kênh để thêm." }
        if busy { return "Đang tải danh sách kênh…" }
        if let e = Iptv.activeList()?.err { return "Không tải được danh sách: \(e)" }
        return "Nhóm này không có kênh."
    }

    // MARK: Bàn phím rời

    func keyMove(_ d: KeyNav.Dir) {
        guard !items.isEmpty else { return }
        let keys = items.map { $0.id }
        guard let cur = keySel, let i = keys.firstIndex(of: cur) else {
            keySel = keys[0]
            return
        }
        let step: Int
        switch d {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -max(1, cols)
        case .down: step = max(1, cols)
        }
        keySel = keys[max(0, min(keys.count - 1, i + step))]
    }

    func keyOpen() {
        guard let k = keySel, let c = items.first(where: { $0.id == k }) else { return }
        open(c)
    }
}

// MARK: - Khung chính «Truyền hình · Radio»

struct TvContent: View {
    @ObservedObject var m = TvModel.shared
    @ObservedObject private var scale = TextScale.shared
    let showMenuButton: Bool
    let openMenu: () -> Void
    @FocusState private var searchFocused: Bool
    /// iPhone dọc: chỉ hai nút tròn (tải lại nằm trong menu danh sách) để tiêu đề không bị cắt
    @Environment(\.horizontalSizeClass) private var hClass

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if m.hasList {
                searchBar
                GeometryReader { geo in
                    let pad: CGFloat = geo.size.width < 500 ? 14 : 20
                    // Cỡ chữ «Rất lớn» / «Cực lớn» trên iPhone hẹp: bề rộng tối thiểu của thẻ lớn hơn màn hình thì lưới tràn sang phải
                    let minW = min(scale.layout(geo.size.width < 500 ? 300 : 290), max(120, geo.size.width - pad * 2))
                    ScrollViewReader { proxy in
                        ScrollView {
                            // MỘT lưới lười duy nhất: đầu trang (kênh vừa xem, nhóm, tiêu đề) là tiêu đề mục, nút trang là chân
                            // mục. Trước đây lưới kênh (cao hàng nghìn điểm) là một phần tử con của LazyVStack: mỗi lần dựng lại
                            // (quay về từ trình phát) SwiftUI ước các phần nhỏ phía trên theo cỡ của lưới → nội dung phình, vuốt
                            // không về được đầu danh sách (iPhone / iPad, 17/11/2026). Cột thường VStack thì iOS 15 sập.
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: minW), spacing: 14)], alignment: .leading, spacing: 14) {
                                Section {
                                    ForEach(m.items) { c in card(c) }
                                } header: {
                                    listHeader(pad)
                                        .padding(.horizontal, -pad) // dải vuốt ngang tràn hết bề ngang như trước
                                        .id("top")
                                } footer: {
                                    listFooter(proxy, pad: pad)
                                        .padding(.horizontal, -pad)
                                }
                            }
                            .padding(.horizontal, pad)
                            .padding(.vertical, 10)
                        }
                        .onAppear { m.cols = KeyNav.columns(width: Double(geo.size.width - pad * 2), minimum: Double(minW), spacing: 14) }
                        .onChange(of: geo.size.width) { w in
                            m.cols = KeyNav.columns(width: Double(w - pad * 2), minimum: Double(minW), spacing: 14)
                        }
                        .onChange(of: m.keySel) { k in
                            guard let k = k else { return }
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(k) }
                        }
                    }
                }
            } else {
                empty
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .background { if !searchFocused { TvShortcuts(m: m) } }
        .background(
            Group {
                NavigationLink(isActive: Binding(get: { m.guideTarget != nil }, set: { if !$0 { m.guideTarget = nil } })) {
                    if let g = m.guideTarget { TvGuideView(filter: g.filter, index: g.index).id(g.id) }
                } label: { EmptyView() }
                NavigationLink(isActive: $m.settingsShown) { TvSettingsView() } label: { EmptyView() }
            }
            .hidden()
        )
        .sheet(isPresented: $m.addShown) {
            TvAddView().preferredColorScheme(.dark).appDynamicType()
        }
        .onAppear { m.start() }
        .onDisappear { m.stop() }
    }

    // MARK: Đầu trang (như màn chính: nút menu, tiêu đề lớn, nút tròn bên phải)

    private var header: some View {
        HStack(spacing: 12) {
            if showMenuButton {
                Button(action: openMenu) {
                    Image(systemName: "line.3.horizontal").appFont(22, .semibold).foregroundColor(Theme.text)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Menu")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Truyền hình · Radio").appFont(26, .bold).foregroundColor(Theme.text).lineLimit(1).minimumScaleFactor(0.6)
                if !m.info.isEmpty {
                    HStack(spacing: 6) {
                        if m.busy { ProgressView().scaleEffect(0.7).tint(Theme.dim) }
                        Text(m.info).appFont(13).foregroundColor(Theme.dim).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if m.hasList {
                Menu {
                    Section("Danh sách kênh") {
                        ForEach(m.lists) { l in
                            Button { m.useList(l.id) } label: {
                                if l.id == m.activeId {
                                    Label("\(l.name)\(l.count > 0 ? "  ·  \(l.count) kênh" : "")", systemImage: "checkmark")
                                } else {
                                    Text("\(l.name)\(l.count > 0 ? "  ·  \(l.count) kênh" : "")")
                                }
                            }
                        }
                    }
                    if hClass == .compact {
                        Button { m.refreshList(force: true) } label: { Label("Tải lại danh sách", systemImage: "arrow.clockwise") }
                            .disabled(m.busy)
                    }
                    Button { m.addShown = true } label: { Label("Thêm danh sách…", systemImage: "plus") }
                    Button { m.settingsShown = true } label: { Label("Quản lý danh sách, lịch phát sóng…", systemImage: "slider.horizontal.3") }
                } label: {
                    HeaderIcon(icon: "list.bullet.rectangle")
                }
                .accessibilityLabel("Đổi danh sách kênh")
                if hClass != .compact {
                    Button { m.refreshList(force: true) } label: { HeaderIcon(icon: "arrow.clockwise") }
                        .buttonStyle(PressScale())
                        .disabled(m.busy)
                        .accessibilityLabel("Tải lại danh sách")
                }
            }
            Button { m.settingsShown = true } label: { HeaderIcon(icon: "gearshape") }
                .buttonStyle(PressScale())
                .accessibilityLabel("Cài đặt Truyền hình")
        }
        .padding(.leading, showMenuButton ? 8 : 20)
        .padding(.trailing, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(Theme.dim)
            TextField("Tìm kênh theo tên hoặc số kênh", text: $m.search)
                .focused($searchFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .foregroundColor(Theme.text)
                .onChange(of: m.search) { m.searchChanged($0) }
            if !m.search.isEmpty {
                Button { m.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Theme.dim) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Xoá chữ tìm")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
        .frame(maxWidth: 640)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: Kênh vừa xem (dải vuốt ngang như «Xem tiếp»)

    private func recentStrip(_ pad: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kênh vừa xem").appFont(21, .semibold).foregroundColor(Theme.text).padding(.horizontal, pad)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(m.recent, id: \.k) { r in
                        Button { m.openRecent(r) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                LogoTile(url: r.logo, radio: r.radio == true, corner: 12)
                                    .frame(width: 168, height: 96)
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: "play.circle.fill")
                                            .appFont(26)
                                            .foregroundColor(.white.opacity(0.95))
                                            .shadow(color: .black.opacity(0.6), radius: 5)
                                            .padding(6)
                                    }
                                Text(r.n).appFont(15, .medium).foregroundColor(Theme.text).lineLimit(1)
                                Text(r.g).appFont(12).foregroundColor(Theme.dim).lineLimit(1)
                            }
                            .frame(width: 168, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScale())
                        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 12))
                        .hoverEffect(.lift)
                    }
                }
                .padding(.horizontal, pad)
                .padding(.vertical, 4)
            }
            .fixedSize(horizontal: false, vertical: true) // trong tiêu đề lưới: cao đúng theo nội dung
        }
    }

    // MARK: Nhóm kênh (một dải chip cuộn ngang — danh sách Xtream có vài trăm nhóm)

    private func groupStrip(_ pad: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                chip("Yêu thích", icon: "star.fill", count: m.groups.favs, active: m.filter.favs) { m.choose(group: nil, favs: true) }
                chip("Tất cả", icon: nil, count: m.groups.total, active: !m.filter.favs && m.filter.group == nil) {
                    m.choose(group: nil, favs: false)
                }
                ForEach(m.groups.groups) { g in
                    chip(g.name, icon: nil, count: g.count, active: !m.filter.favs && m.filter.group == g.id) {
                        m.choose(group: g.id, favs: false)
                    }
                }
            }
            .padding(.horizontal, pad)
            .padding(.vertical, 2)
        }
        .fixedSize(horizontal: false, vertical: true) // trong tiêu đề lưới: cao đúng theo nội dung
    }

    private func chip(_ text: String, icon: String?, count: Int, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let i = icon { Image(systemName: i).appFont(13, .semibold) }
                Text(text).appFont(15, .medium).lineLimit(1)
                Text("\(count)").appFont(13, .semibold).opacity(0.7)
            }
            .foregroundColor(active ? Theme.onBrand : Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(active ? Theme.brand : Theme.surface2))
        }
        .buttonStyle(PressScale())
        .contentShape(.hoverEffect, Capsule())
        .hoverEffect(.highlight)
    }

    private func sectionTitle(_ pad: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(m.sectionTitle).appFont(21, .semibold).foregroundColor(Theme.text).lineLimit(1)
            if m.total > 0 { Text("\(m.total) kênh").appFont(14).foregroundColor(Theme.dim) }
        }
        .padding(.horizontal, pad)
        .padding(.top, 4)
    }

    // MARK: Lưới kênh

    /// Đầu lưới: kênh vừa xem, dải nhóm, tiêu đề mục.
    private func listHeader(_ pad: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !m.recent.isEmpty && m.filter.q.isEmpty { recentStrip(pad) }
            groupStrip(pad)
            sectionTitle(pad)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Chân lưới: chữ báo khi nhóm trống / đang tải, nút trang.
    private func listFooter(_ proxy: ScrollViewProxy, pad: CGFloat) -> some View {
        VStack(spacing: 0) {
            if m.items.isEmpty {
                HStack(spacing: 10) {
                    if m.busy { ProgressView().tint(Theme.dim) }
                    Text(m.emptyText).appFont(16).foregroundColor(Theme.dim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, pad)
                .padding(.vertical, 30)
            }
            pager(proxy, pad: pad)
        }
    }

    private func card(_ c: IptvChannelView) -> some View {
        Button { m.open(c) } label: { TvCard(c: c, now: m.now, selected: m.keySel == c.id) }
            .buttonStyle(PressScale())
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 14))
            .hoverEffect(.lift)
            .contextMenu { menu(c) }
            // Định danh duy nhất: kênh nằm ở nhiều nhóm thì «Tất cả» có hai ô cùng khoá `k` — SwiftUI gặp mã trùng thì tính
            // sai chiều cao lưới (17/11/2026)
            .id(c.id)
    }

    @ViewBuilder
    private func menu(_ c: IptvChannelView) -> some View {
        Button { m.open(c) } label: { Label(c.radio ? "Nghe" : "Xem", systemImage: "play.fill") }
        if c.match == .later || c.match == .soon {
            Button { m.toggleKick(c) } label: {
                Label(Iptv.hasReminder(key: c.k, kick: true) ? "Bỏ nhắc bóng lăn" : "Nhắc lúc bóng lăn", systemImage: "bell")
            }
        }
        if c.match == .none && !c.vod {
            Button { m.guideTarget = TvGuideTarget(filter: m.filter, index: c.index) } label: {
                Label("Lịch phát sóng", systemImage: "calendar")
            }
        }
        Button { m.toggleFavorite(c) } label: {
            Label(c.fav ? "Bỏ khỏi Yêu thích" : "Thêm vào Yêu thích", systemImage: c.fav ? "star.slash" : "star")
        }
        if c.bad != nil {
            Button { m.retry(c) } label: { Label("Thử lại kênh này", systemImage: "arrow.clockwise") }
        }
    }

    @ViewBuilder
    private func pager(_ proxy: ScrollViewProxy, pad: CGFloat) -> some View {
        if m.total > TvModel.pageSize {
            let first = m.offset == 0
            let last = m.offset + TvModel.pageSize >= m.total
            HStack(spacing: 14) {
                Button {
                    m.page(-1)
                    proxy.scrollTo("top")
                } label: { HeaderIcon(icon: "chevron.left") }
                    .buttonStyle(PressScale())
                    .disabled(first)
                    .opacity(first ? 0.4 : 1)
                    .accessibilityLabel("Trang trước")
                Text("Kênh \(m.offset + 1)–\(min(m.offset + TvModel.pageSize, m.total)) / \(m.total)")
                    .appFont(15, .medium).foregroundColor(Theme.dim)
                Button {
                    m.page(1)
                    proxy.scrollTo("top")
                } label: { HeaderIcon(icon: "chevron.right") }
                    .buttonStyle(PressScale())
                    .disabled(last)
                    .opacity(last ? 0.4 : 1)
                    .accessibilityLabel("Trang sau")
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, pad)
            .padding(.vertical, 10)
        }
    }

    // MARK: Chưa có danh sách

    private var empty: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "tv.and.mediabox")
                .appFont(64, .light)
                .foregroundColor(Theme.brand)
            Text("Chưa có danh sách kênh").appFont(24, .bold).foregroundColor(Theme.text)
            Text("App không kèm sẵn kênh. Thêm địa chỉ danh sách M3U / M3U8 (hoặc tệp .m3u trên máy) mà bạn có quyền xem — app đọc nhóm kênh, logo, đài radio và lịch phát sóng ghi trong danh sách.")
                .appFont(16)
                .foregroundColor(Theme.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button { m.addShown = true } label: {
                Label("Thêm danh sách kênh", systemImage: "plus").appFont(17, .semibold).padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.brand)
            .controlSize(.large)
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}

/// Nút tròn nhỏ ở đầu trang.
private struct HeaderIcon: View {
    let icon: String
    var body: some View {
        Image(systemName: icon)
            .appFont(17, .semibold)
            .foregroundColor(Theme.text)
            .frame(width: 40, height: 40)
            .background(Circle().fill(Theme.surface2))
            .contentShape(.hoverEffect, Circle())
            .hoverEffect(.highlight)
    }
}

/// Esc: về trang trước (lịch phát sóng, cài đặt — bàn phím rời / bản Mac).
private struct EscapeKey: View {
    let action: () -> Void

    var body: some View {
        Button("Quay lại", action: action)
            .keyboardShortcut(.escape, modifiers: [])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

/// Phím không có ⌘ của lưới kênh: mũi tên chọn kênh, Enter / Space mở. Tắt lúc đang gõ ô tìm.
private struct TvShortcuts: View {
    @ObservedObject var m: TvModel

    var body: some View {
        ZStack {
            key("Sang trái", .leftArrow) { m.keyMove(.left) }
            key("Sang phải", .rightArrow) { m.keyMove(.right) }
            key("Lên", .upArrow) { m.keyMove(.up) }
            key("Xuống", .downArrow) { m.keyMove(.down) }
            key("Mở kênh", .return) { m.keyOpen() }
            key("Mở kênh", .space) { m.keyOpen() }
        }
        .allowsHitTesting(false)
    }

    private func key(_ title: String, _ k: KeyEquivalent, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .keyboardShortcut(k, modifiers: [])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

/// Ô logo kênh: nền mờ bo tròn, logo vừa khung (chưa có / không tải được: biểu tượng TV / radio).
struct LogoTile: View {
    let url: String?
    var radio = false
    var corner: CGFloat = 10
    @State private var img: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let i = img {
                Image(uiImage: i).resizable().scaledToFit().padding(8)
            } else {
                Image(systemName: radio ? "radio" : "tv").appFont(22, .light).foregroundColor(Theme.dim.opacity(0.7))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .task(id: url) {
            img = nil
            if let u = url { img = await ImageCache.shared.image(u, maxPixel: 240) }
        }
    }
}

/// Thẻ kênh: logo, tên, nhãn (ĐANG ĐÁ / RADIO / PHIM / SẮP ĐÁ), chương trình đang phát + tiến độ, chương trình kế.
struct TvCard: View {
    let c: IptvChannelView
    let now: Double
    var selected = false

    private static let red = Color(hex: 0xE5533D)

    private var lines: (String, String, Double) {
        if let bad = c.bad { return ("Máy này không phát được", bad, -1) }
        if let line = c.matchLine {
            let remind = Iptv.hasReminder(key: c.k, kick: true) ? "🔔 Sẽ nhắc lúc bóng lăn" : c.g
            let f = c.match == .live ? (now - c.kick) / (Double(c.dur) * 60) : -1
            return (Self.shortMatchLine(line), remind, f)
        }
        if let p = c.now {
            let next = c.next.map { "Tiếp theo \(IptvParse.clock($0.s)) · \($0.t)" } ?? c.g
            return (p.t, next, (now - p.s) / max(1, p.e - p.s))
        }
        return (c.g, c.radio ? "Đài phát thanh" : c.vod ? "Phim" : "Chưa có lịch phát sóng", -1)
    }

    /// Nhãn đã ghi «ĐANG ĐÁ» / «SẮP ĐÁ» / «ĐÃ XONG»: dòng dưới bỏ phần lặp lại («● Đang đá · bóng lăn 23:00» → «Bóng lăn 23:00»).
    static func shortMatchLine(_ line: String) -> String {
        for p in ["● Đang đá · ", "Đã xong · "] where line.hasPrefix(p) {
            let rest = line.dropFirst(p.count)
            return rest.prefix(1).uppercased() + rest.dropFirst()
        }
        if line.hasPrefix("Sắp đá ") { return "Bóng lăn " + line.dropFirst(7) }
        return line
    }

    private var tag: (String, Color)? {
        switch c.match {
        case .live: return c.nolink ? ("CHỜ LINK", Theme.focus) : ("● ĐANG ĐÁ", Self.red)
        case .soon: return ("SẮP ĐÁ", Theme.focus)
        case .later: return ("SẮP ĐÁ", Theme.surface2)
        case .over: return ("ĐÃ XONG", Theme.surface2)
        case .none: break
        }
        if c.radio { return ("RADIO", Color(hex: 0x3B82F6)) }
        if c.vod { return ("PHIM", Color(hex: 0x8B5CF6)) }
        return nil
    }

    var body: some View {
        let (l1, l2, frac) = lines
        HStack(alignment: .top, spacing: 12) {
            LogoTile(url: c.logo, radio: c.radio)
                .frame(width: 92, height: 60)
                .overlay(alignment: .topLeading) {
                    Text(c.num)
                        .appFont(11, .bold, mono: true)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .padding(4)
                }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(c.n).appFont(17, .semibold).foregroundColor(Theme.text).lineLimit(1)
                    Spacer(minLength: 0)
                    if c.fav { Image(systemName: "star.fill").appFont(13).foregroundColor(Theme.focus) }
                }
                HStack(spacing: 6) {
                    if let t = tag {
                        Text(t.0)
                            .appFont(10, .bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(t.1))
                            .fixedSize()
                    }
                    Text(l1).appFont(14, .medium).foregroundColor(c.bad == nil ? Theme.text.opacity(0.9) : Theme.dim).lineLimit(1)
                }
                if frac >= 0 {
                    ProgressView(value: min(1, max(0, frac)))
                        .tint(c.match == .live ? Self.red : Theme.brand)
                        .scaleEffect(x: 1, y: 0.7, anchor: .center)
                }
                Text(l2).appFont(13).foregroundColor(Theme.dim).lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay { if selected { RoundedRectangle(cornerRadius: 14).stroke(Theme.focus, lineWidth: 4) } }
        .opacity(c.bad != nil ? 0.55 : c.match == .over ? 0.7 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Thêm danh sách

struct TvAddView: View {
    @ObservedObject var m = TvModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var name = ""
    @State private var picking = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    // Nhiều dòng: dán một lần nhiều địa chỉ, mỗi dòng một danh sách
                    ZStack(alignment: .topLeading) {
                        if url.isEmpty {
                            Text("http://…/danh-sach.m3u\n(dán được nhiều địa chỉ, mỗi dòng một danh sách)")
                                .foregroundColor(Color(uiColor: .placeholderText))
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .frame(minHeight: 88, maxHeight: 180)
                    }
                    TextField("Tên hiện trong app (không bắt buộc)", text: $name)
                } header: {
                    Text("Địa chỉ danh sách M3U / M3U8")
                } footer: {
                    Text("App không kèm sẵn kênh, chỉ thêm danh sách bạn có quyền xem. Danh sách theo địa chỉ tự tải lại khi cũ (danh sách thể thao: mỗi 30 phút).")
                }
                Section {
                    Button { picking = true } label: { Label("Chọn tệp .m3u trên máy…", systemImage: "doc.badge.plus") }
                } footer: {
                    if let e = error { Text(e).foregroundColor(Color(hex: 0xE5533D)) }
                }
            }
            .navigationTitle("Thêm danh sách kênh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Thêm", action: addUrl).disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .text]) { r in
                switch r {
                case .success(let u):
                    do {
                        let l = try Iptv.addFile(u, name: name)
                        dismiss()
                        m.added(l)
                    } catch {
                        self.error = friendly(error)
                    }
                case .failure(let e):
                    self.error = e.localizedDescription
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func addUrl() {
        let r = Iptv.addLists(url, name: name)
        guard let first = r.added.first else {
            error = r.existing == 0 ? "Chưa có địa chỉ danh sách." : r.existing == 1 ? "Danh sách này đã có trong app."
                : "Các danh sách này đã có trong app."
            return
        }
        let skip = r.existing > 0 ? " (bỏ qua \(r.existing) đã có)" : ""
        let text = r.added.count == 1 ? "Đã thêm danh sách «\(first.name)»\(skip) — đang tải kênh…"
            : "Đã thêm \(r.added.count) danh sách\(skip) — đang tải «\(first.name)»; danh sách khác tải khi chọn trong menu danh sách."
        dismiss()
        m.added(first, text: text)
    }
}

// MARK: - Lịch phát sóng (dòng thời gian một ngày)

struct TvGuideView: View {
    let filter: IptvFilter
    let index: Int
    @ObservedObject private var m = TvModel.shared
    @State private var ch: IptvChannelView?
    @State private var loaded = false
    @State private var day = 0
    @State private var version = 0
    @Environment(\.horizontalSizeClass) private var hClass

    private func dayStart(_ offset: Int) -> Double {
        let cal = Calendar.current
        return (cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date())) ?? Date()).timeIntervalSince1970
    }

    private func programmes(_ c: IptvChannelView, _ day: Int) -> [IptvProgramme] {
        let from = dayStart(day)
        let to = dayStart(day + 1)
        return c.programmes.filter { $0.s >= from && $0.s < to }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let c = ch {
                        header(c)
                        Picker("Ngày", selection: $day) {
                            Text("Hôm qua").tag(-1)
                            Text("Hôm nay").tag(0)
                            Text("Ngày mai").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                        timeline(c, proxy)
                    } else if loaded {
                        Text("Danh sách kênh đang chọn không còn kênh này.").appFont(16).foregroundColor(Theme.dim)
                    } else {
                        ProgressView().tint(Theme.text).frame(maxWidth: .infinity).padding(40)
                    }
                }
                .padding(hClass == .compact ? 16 : 24)
            }
        }
        .background(
            ZStack(alignment: .top) {
                Theme.bg
                LogoTile(url: ch?.logo, corner: 0)
                    .frame(height: 300)
                    .frame(maxWidth: .infinity)
                    .blur(radius: 40)
                    .opacity(0.35)
                    .clipped()
                LinearGradient(colors: [.clear, Theme.bg], startPoint: .top, endPoint: .bottom).frame(height: 300)
            }
            .ignoresSafeArea()
        )
        .background(EscapeKey { m.guideTarget = nil })
        .navigationTitle(ch?.n ?? "Lịch phát sóng")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(false)
        .task {
            ch = await Iptv.at(filter, index)
            loaded = true
        }
    }

    private func header(_ c: IptvChannelView) -> some View {
        HStack(alignment: .center, spacing: 16) {
            LogoTile(url: c.logo, radio: c.radio, corner: 14).frame(width: 132, height: 86)
            VStack(alignment: .leading, spacing: 6) {
                Text(c.n).appFont(26, .bold).foregroundColor(Theme.text).lineLimit(2)
                Text("Kênh \(c.num) · \(c.g)\(c.fav ? " · ★ Yêu thích" : "")").appFont(15).foregroundColor(Theme.dim)
                Button { Router.playLive(filter, index) } label: {
                    Label(c.radio ? "Nghe trực tiếp" : "Xem trực tiếp", systemImage: "play.fill").appFont(16, .semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func timeline(_ c: IptvChannelView, _ proxy: ScrollViewProxy) -> some View {
        let rows = programmes(c, day)
        if rows.isEmpty {
            Text(!c.programmes.isEmpty ? "Ngày này chưa có lịch."
                 : Iptv.epgUrl() != nil ? "Kênh này chưa có lịch phát sóng (lịch của danh sách không có kênh này)."
                 : "Danh sách kênh không ghi địa chỉ lịch phát sóng. Đặt trong Cài đặt Truyền hình.")
                .appFont(16).foregroundColor(Theme.dim).padding(.top, 10)
        } else {
            let now = Iptv.nowSec()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, p in
                    // theo thứ tự dòng: lịch EPG có khi trùng giờ bắt đầu — mã trùng làm SwiftUI tính sai / sập
                    row(c, p, now: now, last: i == rows.count - 1).id("p\(i)")
                }
            }
            .id("\(day)-\(version)")
            .onAppear {
                if let ci = rows.firstIndex(where: { $0.s <= now && now < $0.e }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation { proxy.scrollTo("p\(ci)", anchor: .center) } }
                }
            }
        }
    }

    private func row(_ c: IptvChannelView, _ p: IptvProgramme, now: Double, last: Bool) -> some View {
        let live = p.s <= now && now < p.e
        let future = p.s > now
        let remind = future && Iptv.hasReminder(key: c.k, s: p.s, kick: false)
        return HStack(alignment: .top, spacing: 14) {
            Text(IptvParse.clock(p.s))
                .appFont(15, .semibold, mono: true)
                .foregroundColor(live ? Theme.brand : future ? Theme.text : Theme.dim)
                .frame(width: 56, alignment: .leading)
                .padding(.top, 14)
            // Đường thời gian: chấm + vạch nối
            VStack(spacing: 0) {
                Circle()
                    .fill(live ? Theme.brand : future ? Theme.dim.opacity(0.6) : Theme.surface2)
                    .frame(width: live ? 14 : 10, height: live ? 14 : 10)
                    .padding(.top, live ? 17 : 19)
                if !last { Rectangle().fill(Theme.surface2).frame(width: 2) }
            }
            .frame(width: 14)
            Button {
                if live {
                    Router.playLive(filter, index)
                } else if future {
                    let on = Iptv.toggleReminder(key: c.k, name: c.n, title: p.t, s: p.s, kick: false)
                    m.toast(on ? "Sẽ nhắc lúc \(IptvParse.clock(max(p.s - 300, Iptv.nowSec()))) (5 phút trước giờ phát, khi app đang mở)."
                            : "Đã bỏ nhắc.")
                    version += 1
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(p.t).appFont(16, live ? .semibold : .medium).foregroundColor(future || live ? Theme.text : Theme.dim)
                            .multilineTextAlignment(.leading)
                        if live {
                            Text("Đang phát · còn \(max(1, Int(((p.e - now) / 60).rounded(.up)))) phút")
                                .appFont(13, .medium).foregroundColor(Theme.brand)
                            ProgressView(value: min(1, max(0, (now - p.s) / max(1, p.e - p.s)))).tint(Theme.brand)
                        } else {
                            Text("\(IptvParse.clock(p.s))–\(IptvParse.clock(p.e))").appFont(13).foregroundColor(Theme.dim)
                        }
                    }
                    Spacer(minLength: 0)
                    if live {
                        Image(systemName: "play.circle.fill").appFont(28).foregroundColor(Theme.brand)
                    } else if future {
                        Image(systemName: remind ? "bell.fill" : "bell").appFont(18).foregroundColor(remind ? Theme.focus : Theme.dim)
                            .accessibilityLabel(remind ? "Bỏ nhắc" : "Nhắc tôi")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(live ? Theme.brand.opacity(0.14) : Theme.surface.opacity(future ? 1 : 0.6)))
                .overlay { if live { RoundedRectangle(cornerRadius: 12).stroke(Theme.brand.opacity(0.6), lineWidth: 1.5) } }
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(PressScale())
            .disabled(!live && !future)
            .padding(.vertical, 5)
        }
    }
}

// MARK: - Cài đặt Truyền hình

struct TvSettingsView: View {
    @ObservedObject private var m = TvModel.shared
    @State private var epg = Iptv.epgOverride ?? ""
    @State private var hideBad = Iptv.hideBad
    @State private var autoSource = Iptv.autoSource
    @State private var lists = Iptv.lists()
    @State private var active = Iptv.activeList()?.id
    @State private var guideNote = ""

    var body: some View {
        Form {
            Section {
                ForEach(lists) { l in listRow(l) }
                Button { m.addShown = true } label: { Label("Thêm danh sách (địa chỉ / tệp M3U)", systemImage: "plus.circle.fill") }
            } header: {
                Text("Danh sách kênh")
            } footer: {
                Text("App không kèm sẵn kênh. Thêm danh sách M3U / M3U8 mà bạn có quyền xem; app đọc nhóm, logo, đài radio và địa chỉ lịch phát sóng ghi trong danh sách. Danh sách theo địa chỉ tự tải lại khi cũ; danh sách từ tệp thì thêm lại khi có tệp mới.")
            }
            Section {
                TextField("http://…/epg.xml.gz", text: $epg)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                Button {
                    Iptv.setEpgOverride(epg)
                    reloadGuide()
                } label: { Label("Lưu và tải lịch", systemImage: "square.and.arrow.down") }
                Button { reloadGuide() } label: { Label("Tải lại lịch ngay", systemImage: "arrow.clockwise") }
            } header: {
                Text("Lịch phát sóng (EPG)")
            } footer: {
                Text("Địa chỉ lịch XMLTV (.xml / .xml.gz). Để trống = lấy từ danh sách: \(Iptv.activeList()?.epg ?? "danh sách không ghi").\n\(guideNote)")
            }
            Section {
                Toggle("Ẩn kênh máy này không phát được", isOn: $hideBad)
                    .onChange(of: hideBad) { Iptv.hideBad = $0 }
                Toggle("Nguồn lỗi thì tự sang nguồn khác", isOn: $autoSource)
                    .onChange(of: autoSource) { Iptv.autoSource = $0 }
                Button(role: .destructive) {
                    Iptv.clearBad()
                    m.toast("Đã xoá — lần mở sau app thử lại các kênh đó.")
                } label: { Label("Xoá dấu «không phát được»", systemImage: "eraser") }
            } header: {
                Text("Phát")
            } footer: {
                Text("Kênh có nhiều nguồn: nguồn lỗi tự sang nguồn sau. Luồng phát đi thẳng tới máy chủ của kênh (kèm Referer / User-Agent danh sách ghi). Máy này không phát được luồng HTTP-FLV.")
            }
        }
        .tint(Theme.brand)
        .background(EscapeKey { m.settingsShown = false })
        .navigationTitle("Cài đặt Truyền hình")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(false)
        .onAppear(perform: reload)
        .onChange(of: m.addShown) { shown in
            if !shown { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { reload() } }
        }
        .onChange(of: m.lists) { _ in reload() }
    }

    private func reload() {
        lists = Iptv.lists()
        active = Iptv.activeList()?.id
        guideNote = Iptv.guide().map { "\($0.prog.count) kênh có lịch · tải lúc \(IptvParse.clock(Double($0.fetched) / 1000))" } ?? "Chưa tải lịch."
    }

    private func listRow(_ l: IptvList) -> some View {
        let detail = l.err.map { "Lỗi: \($0)" } ?? (l.updated == 0 ? "Chưa tải"
            : "\(l.count) kênh · cập nhật \(IptvParse.clock(Double(l.updated) / 1000))")
        let from = l.url ?? "tệp «\(l.src ?? "")»"
        return HStack(spacing: 12) {
            // Hàng có hai nút (chọn + menu): kiểu .borderless để chạm nút nào chạy nút đó (Form chạy cả hàng)
            Button { use(l) } label: {
                HStack(spacing: 12) {
                    Image(systemName: l.id == active ? "checkmark.circle.fill" : "circle")
                        .appFont(20)
                        .foregroundColor(l.id == active ? Theme.brand : Theme.dim)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(l.name).appFont(16, .medium).foregroundColor(Theme.text)
                        Text(detail).appFont(13).foregroundColor(l.err != nil ? Color(hex: 0xE5533D) : Theme.dim).lineLimit(2)
                        Text(from).appFont(12).foregroundColor(Theme.dim.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            Menu {
                Button { use(l) } label: { Label("Dùng danh sách này", systemImage: "checkmark") }
                Button { reloadList(l) } label: { Label("Tải lại", systemImage: "arrow.clockwise") }
                Button { rename(l) } label: { Label("Đổi tên", systemImage: "pencil") }
                Button(role: .destructive) { remove(l) } label: { Label("Xoá", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").appFont(22).foregroundColor(Theme.dim)
            }
        }
        .padding(.vertical, 2)
    }

    private func use(_ l: IptvList) {
        m.useList(l.id)
        reload()
    }

    private func reloadList(_ l: IptvList) {
        if l.id != active { m.useList(l.id) }
        m.refreshList(force: true)
        reload()
    }

    private func rename(_ l: IptvList) {
        TvAlert.show("Đổi tên danh sách", nil, ["Lưu", "Huỷ"], fields: [(l.name, "Tên danh sách")]) { i, texts in
            if i == 0, let t = texts.first { Iptv.renameList(l.id, t) }
            reload()
            m.rebuild()
        }
    }

    private func remove(_ l: IptvList) {
        TvAlert.show("Xoá danh sách «\(l.name)»?", "Kênh yêu thích vẫn giữ — thêm lại danh sách là có lại.", ["Xoá", "Huỷ"]) { i in
            if i == 0 {
                Iptv.removeList(l.id)
                m.rebuild()
            }
            reload()
        }
    }

    private func reloadGuide() {
        m.toast("Đang tải lịch phát sóng…")
        Task {
            do {
                try await Iptv.refreshGuide(force: true)
                m.toast("Đã tải lịch: \(Iptv.guide()?.prog.count ?? 0) kênh có lịch.")
            } catch {
                m.toast(friendly(error))
            }
            reload()
        }
    }
}
