//! Nhật ký nhỏ: ghi vào ~/.local/share/conbangtv/log.txt (giữ ~500 KB) + vòng 2 000 dòng trong bộ nhớ (cổng gỡ lỗi /log).
//! Bản Windows: Log.cs.

use std::io::Write;
use std::sync::Mutex;

struct State {
    lines: std::collections::VecDeque<(u64, String)>,
    seq: u64,
    file: Option<std::path::PathBuf>,
}

static STATE: Mutex<State> = Mutex::new(State { lines: std::collections::VecDeque::new(), seq: 0, file: None });

/// Gọi một lần lúc mở app (sau Prefs::load).
pub fn start() {
    let f = crate::prefs::data_dir().join("log.txt");
    if let Ok(m) = std::fs::metadata(&f) {
        if m.len() > 500_000 {
            let _ = std::fs::rename(&f, f.with_extension("txt.1"));
        }
    }
    STATE.lock().unwrap().file = Some(f);
}

/// Ghi một dòng nhật ký: `log::d("net", "…")`.
pub fn d(tag: &str, message: &str) {
    let (date, hms) = stamp();
    let message = redact(message);
    let line = format!("{hms} {tag}: {message}");
    if std::env::var_os("CONBANG_DEBUG").is_some() {
        eprintln!("{line}");
    }
    let mut st = STATE.lock().unwrap();
    st.seq += 1;
    let seq = st.seq;
    st.lines.push_back((seq, line.clone()));
    while st.lines.len() > 2000 {
        st.lines.pop_front();
    }
    if let Some(f) = st.file.clone() {
        if let Ok(mut h) = std::fs::OpenOptions::new().create(true).append(true).open(f) {
            let _ = writeln!(h, "{date} {line}");
        }
    }
}

static QUERY_SECRET: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
    regex::Regex::new(r"(?i)([?&](?:username|user|password|pass|pwd|token|key)=)[^&#\s]*").unwrap()
});
static XTREAM_PATH: std::sync::LazyLock<regex::Regex> =
    std::sync::LazyLock::new(|| regex::Regex::new(r"(?i)(/(?:live|movie|series|timeshift)/)[^/\s]+/[^/\s]+/").unwrap());
static USER_INFO: std::sync::LazyLock<regex::Regex> =
    std::sync::LazyLock::new(|| regex::Regex::new(r"(://)[^/\s@]+@").unwrap());

/// Che tài khoản trong link trước khi ghi nhật ký (tệp log.txt nằm trên đĩa, gửi kèm khi báo lỗi): tham số username /
/// password / token… của link, đường dẫn Xtream `/live/<tên>/<mật khẩu>/…`, `user:pass@` trước tên máy chủ. Như TvLog
/// của bản Android.
pub fn redact(s: &str) -> String {
    if !s.contains("://") && !s.contains('=') {
        return s.to_string();
    }
    let s = QUERY_SECRET.replace_all(s, "${1}***");
    let s = XTREAM_PATH.replace_all(&s, "${1}***/***/");
    USER_INFO.replace_all(&s, "${1}***@").into_owned()
}

/// Các dòng có số thứ tự > since; trả kèm số thứ tự cuối để lần sau hỏi tiếp.
pub fn since(since: u64) -> (u64, Vec<String>) {
    let st = STATE.lock().unwrap();
    (st.seq, st.lines.iter().filter(|(s, _)| *s > since).map(|(_, t)| t.clone()).collect())
}

fn stamp() -> (String, String) {
    let ms = crate::util::now_ms();
    let tm = crate::util::local_tm_of((ms / 1000) as i64);
    (
        format!("{:04}-{:02}-{:02}", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday),
        format!("{:02}:{:02}:{:02}.{:03}", tm.tm_hour, tm.tm_min, tm.tm_sec, ms % 1000),
    )
}

#[cfg(test)]
mod tests {
    use super::redact;

    #[test]
    fn hides_credentials_in_links() {
        assert_eq!(
            redact("tải http://tv.example:8080/get.php?username=an&password=b1&type=m3u_plus lỗi"),
            "tải http://tv.example:8080/get.php?username=***&password=***&type=m3u_plus lỗi"
        );
        assert_eq!(redact("VTV1 (nguồn 1/2) http://tv.example/live/an/b1/123.ts"), "VTV1 (nguồn 1/2) http://tv.example/live/***/***/123.ts");
        assert_eq!(redact("https://an:b1@tv.example/x.m3u?token=abc#t"), "https://***@tv.example/x.m3u?token=***#t");
        assert_eq!(redact("danh sách «Thử» — 467 kênh"), "danh sách «Thử» — 467 kênh");
    }
}
