import SwiftUI

/// Chọn trang phim. Mở ra là đo cùng lúc mọi trang: tải trang chủ mất bao lâu, đọc được bao nhiêu phim, kèm điểm video
/// các lần xem trước; trang nhanh nhất có ★ (bản Android: MainActivity.pickSite).
struct SitesView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var checks: [String: Result<SiteCheck, Error>] = [:]
    @State private var sites = Prefs.sites
    @State private var newSite = ""
    @State private var addError = ""

    private var fastest: String? {
        let ok = checks.compactMap { k, r -> (String, Int)? in
            if case .success(let c) = r, c.films > 0 { return (k, c.ms) }
            return nil
        }
        return ok.count >= 2 ? ok.min { $0.1 < $1.1 }?.0 : nil
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(sites, id: \.self) { s in
                        Button { app.selectSite(s) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: s == Prefs.baseUrl ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(s == Prefs.baseUrl ? Theme.brand : Theme.dim)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(Site.hostOf(s).map(Site.displayName) ?? s).appFont(17, .semibold).foregroundColor(Theme.text)
                                    Text(label(s)).appFont(14).foregroundColor(Theme.dim)
                                }
                                Spacer()
                                if s == fastest { Text("★ nhanh nhất").appFont(14, .semibold).foregroundColor(Theme.focus) }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete { idx in
                        // Vuốt sang trái để xoá trang khỏi danh sách (còn ít nhất một trang)
                        for s in idx.map({ sites[$0] }) where Prefs.removeSite(s) { checks[s] = nil }
                        sites = Prefs.sites
                        app.showSiteLabel()
                    }
                } footer: {
                    Text("Vuốt một trang sang trái để xoá khỏi danh sách. Sửa tên miền khi trang đổi tên: Cài đặt.")
                }
                Section {
                    // Trang mẫu đã xoá (vd phimmois.fun): thêm lại một chạm
                    ForEach(Prefs.missingPresets.filter { !sites.contains($0) }, id: \.self) { s in
                        Button { add(s) } label: {
                            Label("Thêm lại \(Site.hostOf(s) ?? s)", systemImage: "plus.circle").foregroundColor(Theme.brand)
                        }
                    }
                    // Nhiều dòng: dán một lần nhiều trang, mỗi dòng một trang
                    SitePasteEditor(text: $newSite)
                    Button("Thêm") { addTyped() }.disabled(newSite.trimmed.isEmpty)
                    if !addError.isEmpty { Text(addError).foregroundColor(.red) }
                } header: { Text("Thêm trang") } footer: {
                    Text("Hỗ trợ các trang kiểu yanhh3d, theme HaLim (hoathinh3d, hhkungfu…), kiểu PhimMoi (phimmois), mephim.ddns.net, KKPhim (kkphim.com), NguonC (phim.nguonc.com), VSMOV (vsmov.com) và CLB Phim Xưa (sc.k-20.xyz). Thêm một trang là chuyển sang trang đó; dán nhiều trang (mỗi dòng một trang) thì chỉ thêm vào danh sách, trang đang xem giữ nguyên.")
                }
            }
            .navigationTitle("Chọn trang phim")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Sửa tên miền…") {
                        app.sheet = nil
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            app.sheet = .settings
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task {
            await withTaskGroup(of: (String, Result<SiteCheck, Error>).self) { group in
                for s in sites {
                    group.addTask {
                        do { return (s, .success(try await Site.check(s))) } catch { return (s, .failure(error)) }
                    }
                }
                for await (s, r) in group { checks[s] = r }
            }
        }
    }

    private func addTyped() {
        // Một tên miền: như trước (thêm rồi chuyển sang trang đó)
        if SitePaste.tokenCount(newSite) <= 1 {
            guard let u = Prefs.normalizeUrl(newSite) else {
                addError = "Tên miền không hợp lệ. Ví dụ đúng: phimmois.fun"
                return
            }
            add(u)
            return
        }
        // Dán nhiều trang
        let r = Prefs.addSites(newSite)
        if r.added.isEmpty {
            addError = SitePaste.noneText(r)
            return
        }
        if r.added.count == 1 {
            add(r.added[0], note: SitePaste.skipNote(r))
            return
        }
        addError = ""
        newSite = ""
        sites = Prefs.sites
        app.showToast(SitePaste.addedText(r))
        // Đo luôn các trang mới (như lúc mở danh sách)
        for s in r.added {
            Task { @MainActor in
                do { checks[s] = .success(try await Site.check(s)) } catch { checks[s] = .failure(error) }
            }
        }
    }

    /// Thêm trang vào danh sách rồi chuyển sang trang đó.
    private func add(_ url: String, note: String = "") {
        addError = ""
        newSite = ""
        Prefs.addSite(url)
        sites = Prefs.sites
        app.showToast("Đã thêm \(Site.hostOf(url) ?? url) vào danh sách trang phim\(note).")
        app.selectSite(url)
    }

    /// vd "0,4 s · 36 phim · video mượt"
    private func label(_ s: String) -> String {
        var parts: [String] = []
        switch checks[s] {
        case .none: parts.append("đang đo…")
        case .failure: parts.append("✗ không vào được")
        case .success(let c):
            parts.append(String(format: "%.1f s", Double(c.ms) / 1000).replacingOccurrences(of: ".", with: ","))
            parts.append(c.films > 0 ? "\(c.films) phim" : "không đọc được phim")
        }
        if let v = PlayStats.siteSummary(Site.hostOf(s)) { parts.append(v) }
        return parts.joined(separator: " · ")
    }
}

/// Ô nhập trang phim nhiều dòng (dán được nhiều trang, mỗi dòng một trang) — dùng ở «Chọn trang phim» và Cài đặt.
struct SitePasteEditor: View {
    @Binding var text: String
    var placeholder = "Tên miền, vd ten-trang.example — dán được nhiều trang, mỗi dòng một trang"

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundColor(Color(uiColor: .placeholderText))
                    .padding(.top, 8)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .frame(minHeight: 64, maxHeight: 160)
        }
    }
}

/// Câu báo khi dán nhiều trang phim một lần.
enum SitePaste {
    typealias Result = (added: [String], existing: Int, invalid: Int)

    /// Số chữ (cách nhau bởi dấu cách / xuống dòng) — một chữ thì giữ cách thêm một trang như trước.
    static func tokenCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// «a, b, c» — dài thì «a, b, c… (+4)» (như bản TV / Windows / Linux).
    static func names(_ list: [String]) -> String {
        let hosts = list.map { Site.hostOf($0) ?? $0 }
        return hosts.count > 4 ? hosts.prefix(3).joined(separator: ", ") + "… (+\(hosts.count - 3))"
            : hosts.joined(separator: ", ")
    }

    /// « (bỏ qua 1 đã có; 2 tên miền không hợp lệ)» — rỗng nếu không bỏ qua gì.
    static func skipNote(_ r: Result) -> String {
        var skip: [String] = []
        if r.existing > 0 { skip.append("bỏ qua \(r.existing) đã có") }
        if r.invalid > 0 { skip.append("\(r.invalid) tên miền không hợp lệ") }
        return skip.isEmpty ? "" : " (\(skip.joined(separator: "; ")))"
    }

    static func addedText(_ r: Result) -> String {
        "Đã thêm \(r.added.count) trang: \(names(r.added))\(skipNote(r))."
    }

    static func noneText(_ r: Result) -> String {
        switch r.existing {
        case 0: return "Chưa có tên miền hợp lệ (vd ten-trang.example)."
        case 1: return "Trang này đã có trong danh sách."
        default: return "Các trang này đã có trong danh sách."
        }
    }
}

/// Thể loại / quốc gia đủ danh sách (trang kiểu PhimMoi).
struct FilterView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let title: String
    let items: [Category]

    var body: some View {
        NavigationView {
            List(items) { c in
                Button { app.pickCategory(c) } label: {
                    Text(c.title).foregroundColor(Theme.text)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } } }
        }
        .navigationViewStyle(.stack)
    }
}
