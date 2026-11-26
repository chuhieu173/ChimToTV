import Foundation

/// Nhật ký trong bộ nhớ (vòng 2 000 dòng): bản thử đọc qua cổng gỡ lỗi (/log), thay cho logcat của bản Android.
enum Log {
    private static let lock = NSLock()
    private static var lines: [(seq: Int, text: String)] = []
    private static var seq = 0
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let querySecret = try! NSRegularExpression(pattern: #"(?i)([?&](?:username|user|password|pass|pwd|token|key)=)[^&#\s]*"#)
    private static let xtreamPath = try! NSRegularExpression(pattern: #"(?i)(/(?:live|movie|series|timeshift)/)[^/\s]+/[^/\s]+/"#)
    private static let userInfo = try! NSRegularExpression(pattern: #"(://)[^/\s@]+@"#)
    /// Mã thiết bị của máy chủ TubeMini: `https://<tên miền>/u/<mã>/…`
    private static let devicePath = try! NSRegularExpression(pattern: #"(://[^/\s]+/u/)[^/\s?#]+"#)

    /// Che tài khoản trong link trước khi ghi nhật ký: tham số username / password / token… của link, đường dẫn Xtream
    /// `/live/<tên>/<mật khẩu>/…`, `user:pass@` trước tên máy chủ (như TvLog của bản Android, log::redact của lõi Rust), mã thiết bị
    /// TubeMini `/u/<mã>`.
    static func redact(_ s: String) -> String {
        guard s.contains("://") || s.contains("=") else { return s }
        var out = s
        for (rx, tpl) in [(querySecret, "$1***"), (xtreamPath, "$1***/***/"), (userInfo, "$1***@"), (devicePath, "$1***")] {
            out = rx.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: tpl)
        }
        return out
    }

    static func d(_ tag: String, _ message: String) {
        let line = "\(fmt.string(from: Date())) \(tag): \(redact(message))"
        lock.lock()
        seq += 1
        lines.append((seq, line))
        if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
        lock.unlock()
        #if DEBUG
        print(line)
        #endif
    }

    /// Các dòng có số thứ tự > since; trả kèm số thứ tự cuối để lần sau hỏi tiếp.
    static func since(_ since: Int) -> (last: Int, lines: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (seq, lines.filter { $0.seq > since }.map { $0.text })
    }
}
