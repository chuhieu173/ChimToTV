//! Truyền hình (IPTV) — danh sách kênh M3U / M3U8 người xem tự thêm (app không kèm sẵn kênh), lịch phát sóng XMLTV, đài radio,
//! danh sách thể thao theo giờ trận. Cùng cách đọc với bản Legacy (CBIPTV.m) và bản tivi (Iptv.kt / IptvParse.kt); dùng chung
//! cho Windows (qua conbang_core.dll — lệnh `iptv.*`) và Linux.
//!
//! - Danh sách lưu nguyên tệp ở `<data_dir>/iptv/<mã>.m3u` (thêm từ tệp: `iptv/files/<mã>.m3u`), đọc vào RAM khi cần (danh sách
//!   Xtream 350 nghìn mục ~100 MB — máy tính đủ); tải lại khi cũ quá 6 giờ (có trận: 30 phút; trận sắp / đang đá chưa có link
//!   thật: 5 phút); tệp tải về y như lần trước (CRC32) thì khỏi đọc lại.
//! - Lịch XMLTV (.xml / .gz) đọc dần, chỉ giữ chương trình của kênh trong danh sách, từ 24 giờ trước tới 48 giờ sau;
//!   lưu `iptv/epg-<mã>.json`.
//! - Khoá cài đặt như Legacy / tivi: iptv_lists, iptv_active, iptv_epg_url, iptv_bad, iptv_hide_bad, iptv_auto_source (cả nhà),
//!   iptv_favs, iptv_recent (từng người xem), iptv_reminders.

use crate::prefs;
use crate::util::{now_ms, Error, Result};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Read};
use std::path::PathBuf;
use std::sync::{Arc, LazyLock, Mutex};
use unicode_normalization::char::is_combining_mark;
use unicode_normalization::UnicodeNormalization;

/// Kênh trận đấu thường lên sóng trước giờ bóng lăn chừng này (giây).
pub const MATCH_EARLY: f64 = 30.0 * 60.0;
const LIST_MAX_AGE: i64 = 6 * 3600 * 1000;
const MATCH_LIST_MAX_AGE: i64 = 30 * 60 * 1000;
const WAITING_LIST_MAX_AGE: i64 = 5 * 60 * 1000;
const AUTO_RETRY_GAP: i64 = 3 * 60 * 1000;
const GUIDE_MAX_AGE: i64 = 6 * 3600 * 1000;
/// Đổi cách đọc → dấu tệp cũ không khớp (đọc lại).
const PARSE_VERSION: u32 = 3;

pub fn now_sec() -> f64 {
    now_ms() as f64 / 1000.0
}

// ======================================================================================================================
// Đọc M3U (thuần — có test)
// ======================================================================================================================

fn key_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'-'
}

/// Thuộc tính `khoá="giá trị"` của dòng #EXTINF / #EXTM3U (khoá chữ thường).
pub fn attrs(s: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let b = s.as_bytes();
    let mut from = 0;
    while let Some(i) = s[from..].find("=\"").map(|x| x + from) {
        let mut k = i;
        while k > 0 && key_char(b[k - 1]) {
            k -= 1;
        }
        let Some(end) = s[i + 2..].find('"').map(|x| x + i + 2) else { break };
        if k < i {
            out.insert(s[k..i].to_ascii_lowercase(), s[i + 2..end].to_string());
        }
        from = end + 1;
    }
    out
}

/// Tên kênh sau dấu phẩy đầu tiên nằm ngoài ngoặc kép của dòng #EXTINF.
pub fn extinf_name(line: &str) -> Option<&str> {
    let mut quoted = false;
    for (i, c) in line.char_indices() {
        if c == '"' {
            quoted = !quoted;
        } else if c == ',' && !quoted {
            return Some(line[i + 1..].trim());
        }
    }
    None
}

/// Địa chỉ http đầu tiên trong chuỗi nhiều địa chỉ cách nhau bằng dấu phẩy (url-tvg="a.xml,b.xml.gz").
pub fn first_url(s: &str) -> Option<String> {
    s.split(',').map(str::trim).find(|t| t.starts_with("http://") || t.starts_with("https://")).map(String::from)
}

/// Một mục của danh sách M3U (một dòng #EXTINF + dòng địa chỉ).
#[derive(Debug, Clone)]
pub struct Entry {
    pub name: String,
    pub group: String,
    pub url: String,
    pub attrs: HashMap<String, String>,
    pub referer: Option<String>,
    pub ua: Option<String>,
}

/// Đọc danh sách M3U theo từng dòng (không giữ cả tệp): #EXTINF, #EXTGRP, #EXTVLCOPT http-referrer / http-user-agent,
/// «url|Referer=…&User-Agent=…» (kiểu Kodi). `epg` = địa chỉ lịch ghi ở dòng #EXTM3U.
#[derive(Default)]
pub struct Reader {
    attrs: HashMap<String, String>,
    name: Option<String>,
    group: Option<String>,
    referer: Option<String>,
    ua: Option<String>,
    started: bool,
    pub epg: Option<String>,
    pub saw_extinf: bool,
}

impl Reader {
    pub fn line(&mut self, raw: &str) -> Option<Entry> {
        let mut l = raw.trim();
        if !self.started {
            self.started = true;
            l = l.trim_start_matches('\u{feff}');
        }
        if l.is_empty() {
            return None;
        }
        if l.starts_with("#EXTM3U") {
            let h = attrs(l);
            if let Some(u) = h.get("url-tvg").or(h.get("x-tvg-url")).or(h.get("tvg-url")).and_then(|v| first_url(v)) {
                self.epg = Some(u);
            }
        } else if l.starts_with("#EXTINF") {
            self.saw_extinf = true;
            let n = extinf_name(l);
            let head = match n {
                Some(n) => &l[..l.len() - n.len()],
                None => l,
            };
            self.attrs = attrs(head);
            self.name = n.filter(|x| !x.is_empty()).map(String::from).or_else(|| self.attrs.get("tvg-name").cloned());
            self.group = self.attrs.get("group-title").cloned();
            self.referer = None;
            self.ua = None;
        } else if let Some(g) = l.strip_prefix("#EXTGRP:") {
            self.group = Some(g.trim().to_string());
        } else if let Some(o) = l.strip_prefix("#EXTVLCOPT:") {
            if let Some((k, v)) = o.split_once('=') {
                let k = k.to_ascii_lowercase();
                if k == "http-referrer" || k == "http-referer" {
                    self.referer = Some(v.to_string());
                }
                if k == "http-user-agent" {
                    self.ua = Some(v.to_string());
                }
            }
        } else if !l.starts_with('#') {
            let mut url = l;
            if let Some((u, opts)) = l.split_once('|') {
                for kv in opts.split('&') {
                    let Some((k, v)) = kv.split_once('=') else { continue };
                    let v = percent_encoding::percent_decode_str(v).decode_utf8_lossy().to_string();
                    match k.to_ascii_lowercase().as_str() {
                        "referer" | "referrer" => self.referer = Some(v),
                        "user-agent" => self.ua = Some(v),
                        _ => {}
                    }
                }
                url = u;
            }
            let mut out = None;
            if url.starts_with("http://") || url.starts_with("https://") {
                let name = self.name.take().filter(|n| !n.is_empty()).unwrap_or_else(|| last_segment(url));
                out = Some(Entry {
                    name,
                    group: self.group.take().filter(|g| !g.is_empty()).unwrap_or_else(|| "Khác".into()),
                    url: url.to_string(),
                    attrs: std::mem::take(&mut self.attrs),
                    referer: self.referer.take(),
                    ua: self.ua.take(),
                });
            }
            self.attrs.clear();
            self.name = None;
            self.group = None;
            self.referer = None;
            self.ua = None;
            return out;
        }
        None
    }
}

fn last_segment(url: &str) -> String {
    let u = url.split('?').next().unwrap_or(url).trim_end_matches('/');
    let s = u.rsplit('/').next().unwrap_or(u);
    if s.is_empty() { url.to_string() } else { s.to_string() }
}

/// Phần đường dẫn (chữ thường) của địa chỉ.
pub fn path_of(url: &str) -> String {
    let s = url.find("://").map(|i| i + 3).unwrap_or(0);
    let Some(slash) = url[s..].find('/').map(|i| i + s) else { return "/".into() };
    let rest = &url[slash..];
    let end = rest.find(['?', '#']).unwrap_or(rest.len());
    rest[..end].to_lowercase()
}

pub fn ext_of_path(path: &str) -> String {
    let last = path.rsplit('/').next().unwrap_or(path);
    match last.rfind('.') {
        Some(d) => last[d + 1..].to_string(),
        None => String::new(),
    }
}

pub fn ext_of(url: &str) -> String {
    ext_of_path(&path_of(url))
}

/// Luồng HTTP-FLV (kênh thể thao): xếp sau HLS.
pub fn is_flv(url: &str) -> bool {
    ext_of(url) == "flv"
}

static NO_SIGNAL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)no[-_]?signal").unwrap());

/// Link giả «không có tín hiệu» mà danh sách thể thao để cho trận chưa có link thật (…/no-signal/low.m3u8: một ảnh 10 s).
pub fn is_placeholder(url: &str) -> bool {
    let p = path_of(url);
    p.contains("signal") && NO_SIGNAL.is_match(&p)
}

/// Thứ tự nguồn của một kênh: HLS / khác → FLV → link giả.
pub fn source_rank(url: &str) -> u8 {
    if is_placeholder(url) {
        2
    } else if is_flv(url) {
        1
    } else {
        0
    }
}

const VOD_EXT: &[&str] = &["mp4", "mkv", "avi", "mov", "m4v", "webm", "mpg", "mpeg", "wmv", "3gp"];

/// Phim / tập phim (VOD) của danh sách Xtream: tệp video, hoặc đường dẫn /movie/ /series/. Phát được tua.
pub fn is_vod_path(p: &str) -> bool {
    VOD_EXT.contains(&ext_of_path(p).as_str()) || p.contains("/movie/") || p.contains("/series/")
}

pub fn is_vod(url: &str) -> bool {
    is_vod_path(&path_of(url))
}

/// Đài radio: danh sách ghi `radio="true"`, nhóm «Radio» / «Phát thanh» / «Truyền thanh» (tên nhóm đã chuẩn hoá), hoặc link
/// tệp tiếng / danh sách của đài (.mp3, .aac, .pls).
pub fn is_radio(attrs: &HashMap<String, String>, group_norm: &str, ext: &str) -> bool {
    if let Some(r) = attrs.get("radio").map(|r| r.to_ascii_lowercase()) {
        if r == "true" || r == "1" {
            return true;
        }
    }
    if group_norm.contains("radio") || group_norm.contains("phatthanh") || group_norm.contains("truyenthanh") {
        return true;
    }
    matches!(ext, "mp3" | "aac" | "pls")
}

const KIDS: &[&str] = &["thieunhi", "kid", "child", "cartoon", "hoathinh", "disney", "nick", "boomerang", "baby", "junior", "anime"];

/// Hồ sơ trẻ em: kênh nhóm thiếu nhi / hoạt hình.
pub fn is_kids(group_norm: &str, key: &str) -> bool {
    KIDS.iter().any(|w| group_norm.contains(w) || key.contains(w))
}

static BRACKETS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\([^)]*\)|\[[^\]]*\]").unwrap());
const TAILS: &[&str] = &["backup", "1080p", "720p", "uhd", "fhd", "hd", "sd", "4k"];

/// Tên chuẩn hoá để so / tìm: bỏ phần trong ngoặc, bỏ dấu, chữ thường, chỉ giữ chữ / số, bỏ «HD», «FHD»… ở cuối.
pub fn norm(name: &str) -> String {
    if name.is_empty() {
        return String::new();
    }
    let mut s = name.to_string();
    if s.contains('(') || s.contains('[') {
        let bare = BRACKETS.replace_all(&s, "").to_string();
        if !bare.trim().is_empty() {
            s = bare;
        }
    }
    let lower = s.to_lowercase().replace('đ', "d");
    let t: String = if lower.is_ascii() {
        lower.chars().filter(|c| c.is_ascii_alphanumeric()).collect()
    } else {
        lower.nfd().filter(|c| c.is_alphanumeric() && !is_combining_mark(*c)).collect()
    };
    let mut end = t.len();
    loop {
        let before = end;
        for x in TAILS {
            if end >= x.len() && t[..end].ends_with(x) {
                end -= x.len();
                break;
            }
        }
        if end == before || end == 0 {
            break;
        }
    }
    if end > 0 { t[..end].to_string() } else { t }
}

static COUNTRY_TAG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\|?[A-Z0-9]{2,5}\|\s*").unwrap());
static PARENS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s*(\([^)]*\)|\[[^\]]*\])").unwrap());
static TAGS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[[^\]]*\]").unwrap());
static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s{2,}").unwrap());

/// Tên hiển thị của kênh thường: bỏ mã nước đầu tên kiểu Xtream («|UK| SPORT 1», «DE| ZDF») và phần trong ngoặc.
pub fn display_name(name: &str) -> String {
    let mut n = name.to_string();
    if n.contains('|') {
        let t = COUNTRY_TAG.replace(&n, "").to_string();
        if !t.is_empty() {
            n = t;
        }
    }
    if !n.contains('(') && !n.contains('[') {
        return n.trim().to_string();
    }
    let b = PARENS.replace_all(&n, "").trim().to_string();
    if b.is_empty() { n } else { b }
}

// ---- Giờ trận («20:00 16/11 ⚽ A vs B (BLV …) [hls]») ----

static TIME_FIRST: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(\d{1,2})[:hH](\d{2})\s*[-,|·]?\s*(?:ngày\s*)?(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?").unwrap()
});
static DATE_FIRST: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\s*[-,|·]?\s*(\d{1,2})[:hH](\d{2})").unwrap());
static MATCHY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\bvs?\.?\s|\s[-–]\s|BLV|⚽|🏀|🎾|🥎|🏐|🏸|🏒|🥊|🏈|⚾").unwrap());

pub struct Kick {
    pub at: f64,
    pub start: usize,
    pub end: usize,
}

fn boundary_ok(s: &str, start: usize, end: usize) -> bool {
    let bad = |c: Option<char>| matches!(c, Some('0'..='9') | Some(':') | Some('/'));
    !bad(s[..start].chars().next_back()) && !bad(s[end..].chars().next())
}

/// Ngày (từ 1970-01-01) của một ngày dương lịch (Howard Hinnant).
pub fn days_from_civil(year: i64, m: i64, d: i64) -> i64 {
    let y = year - if m <= 2 { 1 } else { 0 };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// Năm dương lịch của một ngày (từ 1970-01-01).
fn year_of_days(z: i64) -> i64 {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    yoe + era * 400 + if m <= 2 { 1 } else { 0 }
}

/// Giờ trận ghi trong tên kênh → giây từ 1970. Giờ Việt Nam (UTC+7); không ghi năm thì lấy năm gần bây giờ nhất.
pub fn kickoff(name: &str, now: f64) -> Option<Kick> {
    if !name.contains('/') {
        return None;
    }
    let found = |re: &Regex| re.captures_iter(name).find(|c| { let m = c.get(0).unwrap(); boundary_ok(name, m.start(), m.end()) });
    let (caps, tf) = match found(&TIME_FIRST) {
        Some(c) => (c, true),
        None => (found(&DATE_FIRST)?, false),
    };
    let g = |i: usize| caps.get(i).and_then(|m| m.as_str().parse::<i64>().ok()).unwrap_or(0);
    let (h, mi, d, mo, mut y) = if tf { (g(1), g(2), g(3), g(4), g(5)) } else { (g(4), g(5), g(1), g(2), g(3)) };
    if h > 23 || mi > 59 || !(1..=31).contains(&d) || !(1..=12).contains(&mo) {
        return None;
    }
    if (1..100).contains(&y) {
        y += 2000;
    }
    let now_year = year_of_days(((now + 7.0 * 3600.0) / 86400.0).floor() as i64);
    let years = if y != 0 { y..=y } else { now_year - 1..=now_year + 1 };
    let mut best = f64::NAN;
    for yy in years {
        let t = days_from_civil(yy, mo, d) as f64 * 86400.0 + (h * 3600 + mi * 60 - 7 * 3600) as f64;
        if best.is_nan() || (t - now).abs() < (best - now).abs() {
            best = t;
        }
    }
    let m = caps.get(0).unwrap();
    Some(Kick { at: best, start: m.start(), end: m.end() })
}

pub fn is_match_name(name: &str) -> bool {
    MATCHY.is_match(name)
}

/// Thời lượng trận (phút) theo môn ghi trong tên — để biết lúc nào «Đã xong».
pub fn match_minutes(name: &str) -> u32 {
    if name.contains('⚽') {
        130
    } else if name.contains('🎾') || name.contains('🥎') {
        200
    } else {
        150
    }
}

/// Emoji mới hơn máy cũ vẽ được (🟢 🥅…): bỏ (🥎 → 🎾) — cùng tên với bản tivi / Legacy.
pub fn old_emoji(input: &str) -> String {
    let s = input.replace('🥎', "🎾");
    let s: String = s
        .chars()
        .filter(|&c| {
            let cp = c as u32;
            !(cp >= 0x1F900 || (0x1F7E0..=0x1F7FF).contains(&cp) || (0x1F3CF..=0x1F3D3).contains(&cp) ||
                (0x1F3F8..=0x1F3FF).contains(&cp) || (0x1F6D0..=0x1F6FF).contains(&cp))
        })
        .collect();
    SPACES.replace_all(&s, " ").trim().to_string()
}

/// Tên trận hiển thị: bỏ chỗ ghi giờ và các thẻ «[hls]», «[FHD]»; giữ «(BLV …)» — mỗi BLV là một kênh.
pub fn match_name(name: &str, kick: &Kick) -> String {
    let n = format!("{} {}", &name[..kick.start], &name[kick.end..]);
    let bare = old_emoji(&TAGS.replace_all(&n, ""));
    if bare.is_empty() { n.trim().to_string() } else { bare }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Match {
    None,
    Later,
    Soon,
    Live,
    Over,
}

pub fn match_state(kick: f64, dur: u32, now: f64) -> Match {
    if kick <= 0.0 {
        Match::None
    } else if now < kick - MATCH_EARLY {
        Match::Later
    } else if now < kick {
        Match::Soon
    } else if now < kick + dur as f64 * 60.0 {
        Match::Live
    } else {
        Match::Over
    }
}

/// «19:00» giờ máy.
pub fn clock(t: f64) -> String {
    crate::util::local_hm((t * 1000.0) as i64)
}

fn local_days(t: f64) -> i64 {
    let tm = crate::util::local_tm_of(t as i64);
    days_from_civil(tm.tm_year as i64 + 1900, tm.tm_mon as i64 + 1, tm.tm_mday as i64)
}

/// «20:00», «02:45 mai», «20:00 hôm qua», «20:00 18/11» (giờ máy).
pub fn kick_text(kick: f64, now: f64) -> String {
    let c = clock(kick);
    match local_days(kick) - local_days(now) {
        0 => c,
        1 => format!("{c} mai"),
        -1 => format!("{c} hôm qua"),
        _ => {
            let tm = crate::util::local_tm_of(kick as i64);
            format!("{c} {}/{}", tm.tm_mday, tm.tm_mon + 1)
        }
    }
}

/// «Sắp đá 20:00 · còn 25 phút», «● Đang đá · bóng lăn 20:00», «Đã xong · đá lúc 20:00»; None = kênh thường.
pub fn match_line(kick: f64, dur: u32, nolink: bool, now: f64) -> Option<String> {
    let when = kick_text(kick, now);
    let left = ((kick - now) / 60.0).ceil() as i64;
    Some(match match_state(kick, dur, now) {
        Match::None => return None,
        Match::Later if left >= 24 * 60 => format!("Sắp đá {when}"),
        Match::Later if left >= 60 => format!("Sắp đá {when} · còn {} giờ {:02} phút", left / 60, left % 60),
        Match::Later => format!("Sắp đá {when} · còn {left} phút"),
        Match::Soon => format!("Sắp đá {when} · còn {} phút", left.max(1)),
        Match::Live if nolink => "● Đang đá · danh sách chưa có link".into(),
        Match::Live => format!("● Đang đá · bóng lăn {when}"),
        Match::Over => format!("Đã xong · đá lúc {when}"),
    })
}

/// «20261116190000 +0700» → giây từ 1970 (UTC).
pub fn xmltv_time(s: &str) -> Option<f64> {
    let b = s.as_bytes();
    if b.len() < 12 {
        return None;
    }
    let widths = [4usize, 2, 2, 2, 2, 2];
    let mut v = [0i64; 6];
    let mut p = 0;
    for (i, w) in widths.iter().enumerate() {
        if i == 5 && (p >= b.len() || !b[p].is_ascii_digit()) {
            break;
        }
        for _ in 0..*w {
            if p >= b.len() || !b[p].is_ascii_digit() {
                return None;
            }
            v[i] = v[i] * 10 + (b[p] - b'0') as i64;
            p += 1;
        }
    }
    let mut t = (days_from_civil(v[0], v[1], v[2]) * 86400 + v[3] * 3600 + v[4] * 60 + v[5]) as f64;
    while p < b.len() && b[p] == b' ' {
        p += 1;
    }
    if p + 4 < b.len() && (b[p] == b'+' || b[p] == b'-') && b[p + 1..p + 5].iter().all(u8::is_ascii_digit) {
        let d = |i: usize| (b[p + i] - b'0') as i64;
        let off = ((d(1) * 10 + d(2)) * 3600 + (d(3) * 10 + d(4)) * 60) as f64;
        t -= if b[p] == b'+' { off } else { -off };
    }
    Some(t)
}

/// Danh sách phát là đoạn phim ngắn có hồi kết (hình chờ «không có tín hiệu» thay cho luồng trực tiếp).
pub fn is_placeholder_playlist(m3u8: &str) -> bool {
    if !m3u8.contains("#EXT-X-ENDLIST") || m3u8.contains("#EXT-X-STREAM-INF") {
        return false;
    }
    let total: f64 = m3u8
        .lines()
        .filter_map(|l| l.strip_prefix("#EXTINF:"))
        .map(|x| x.split(',').next().unwrap_or("").trim().parse::<f64>().unwrap_or(0.0))
        .sum();
    total < 120.0
}

/// Luồng `url` (HLS) là hình chờ ngắn có hồi kết (danh sách chính thì xem bản đầu)? Trình phát hỏi khi luồng báo độ dài ngắn —
/// mpv báo độ dài cả cho luồng trực tiếp (cửa sổ trượt) nên không dựa vào đó được.
pub async fn check_placeholder(url: &str, referer: Option<&str>, ua: Option<&str>) -> bool {
    let mut h: Vec<(&str, &str)> = Vec::new();
    if let Some(r) = referer {
        h.push(("Referer", r));
    }
    if let Some(u) = ua {
        h.push(("User-Agent", u));
    }
    let Ok(r) = crate::http::get(url, &h).await else { return false };
    let mut text = r.body();
    if text.contains("#EXT-X-STREAM-INF") {
        let Some(first) = text.lines().map(str::trim).find(|l| !l.is_empty() && !l.starts_with('#')).map(String::from) else { return false };
        let Some(v) = url::Url::parse(&r.url).ok().and_then(|b| b.join(&first).ok()) else { return false };
        let Ok(r2) = crate::http::get(v.as_str(), &h).await else { return false };
        text = r2.body();
    }
    is_placeholder_playlist(&text)
}

static STAMP: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[-_ ]*\d{4}-\d{2}-\d{2}([T_ ]?[\d.:-]*)?$").unwrap());

/// Tên danh sách lấy từ tên tệp: «4k viptv-playlist---2026-11-11T131814-437.m3u» → «4k viptv-playlist».
pub fn name_from_file(file: &str) -> String {
    let base = file.rsplit(['/', '\\']).next().unwrap_or(file);
    let base = match base.rfind('.') {
        Some(i) => &base[..i],
        None => base,
    };
    let n = STAMP.replace(base, "").replace('_', " ");
    let n = n.trim_matches(|c| c == ' ' || c == '-' || c == '.');
    if n.is_empty() { "Danh sách từ tệp".into() } else { n.chars().take(40).collect() }
}

/// Tên danh sách lấy từ địa chỉ: tên tệp (bỏ đuôi), không có thì tên máy chủ.
pub fn name_from_url(u: &str) -> String {
    let parsed = url::Url::parse(u).ok();
    let path = parsed.as_ref().map(|p| p.path().to_string()).unwrap_or_default();
    let file = path.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    let file = match file.rfind('.') {
        Some(i) => &file[..i],
        None => file,
    }
    .replace('_', " ");
    if file.chars().count() > 2 {
        file
    } else {
        parsed.and_then(|p| p.host_str().map(String::from)).unwrap_or_else(|| "Danh sách kênh".into())
    }
}

// ======================================================================================================================
// Kênh của một danh sách (trong RAM)
// ======================================================================================================================

/// Kênh: [urls] = các nguồn (HLS trước FLV, link giả cuối); [hdr] = Referer / UA riêng của nguồn gộp vào từ dòng khác.
#[derive(Debug, Clone)]
pub struct Channel {
    pub k: String,
    pub n: String,
    pub g: u32,
    pub num: String,
    pub logo: Option<String>,
    pub tid: Option<String>,
    pub urls: Vec<String>,
    pub referer: Option<String>,
    pub ua: Option<String>,
    pub hdr: Vec<(String, String, String)>,
    pub kick: f64,
    pub dur: u32,
    pub radio: bool,
    pub vod: bool,
    pub kids: bool,
}

impl Channel {
    pub fn nolink(&self) -> bool {
        self.urls.iter().all(|u| is_placeholder(u))
    }

    /// Referer / User-Agent gửi lên máy chủ cho nguồn `url`.
    pub fn headers_for(&self, url: &str) -> (Option<String>, Option<String>) {
        if let Some((_, r, u)) = self.hdr.iter().find(|h| h.0 == url) {
            return (Some(r.clone()).filter(|x| !x.is_empty()), Some(u.clone()).filter(|x| !x.is_empty()));
        }
        (self.referer.clone(), self.ua.clone())
    }

    pub fn guide_keys(&self) -> Vec<String> {
        let mut v = Vec::new();
        if let Some(t) = &self.tid {
            v.push(t.clone());
        }
        v.push(format!("n:{}", self.k));
        v
    }
}

/// Danh sách đã đọc.
pub struct Loaded {
    pub list_id: String,
    pub channels: Vec<Channel>,
    pub groups: Vec<String>,
    pub has_matches: bool,
    pub epg: Option<String>,
    pub entries: usize,
    pub saw_extinf: bool,
    by_key: HashMap<String, u32>,
}

impl Loaded {
    pub fn by_key(&self, k: &str) -> Option<(u32, &Channel)> {
        self.by_key.get(k).map(|&i| (i, &self.channels[i as usize]))
    }
}

/// Đọc danh sách M3U (luồng chữ) thành kênh: trùng tên (chuẩn hoá) trong cùng nhóm gộp thành nhiều nguồn; kênh thể thao ghi giờ
/// trận trong tên thì tách giờ ra, mỗi BLV một kênh.
pub fn build(list_id: &str, input: impl BufRead, now: f64) -> Loaded {
    let mut r = Reader::default();
    let mut channels: Vec<Channel> = Vec::new();
    let mut groups: Vec<String> = Vec::new();
    let mut group_ix: HashMap<String, (u32, String, bool)> = HashMap::new();
    let mut merge: HashMap<(String, u32), u32> = HashMap::new();
    let mut has_matches = false;
    let mut entries = 0usize;
    let mut index = 0usize;
    let mut add = |e: Entry, channels: &mut Vec<Channel>, groups: &mut Vec<String>| {
        entries += 1;
        index += 1;
        let mut n = e.name.clone();
        let kick = kickoff(&n, now).filter(|_| is_match_name(&e.name));
        let k;
        let mut minutes = 0;
        if let Some(kk) = &kick {
            has_matches = true;
            minutes = match_minutes(&n);
            n = match_name(&n, kk);
            k = format!("{}@{}", norm(&n.replace(['(', ')'], " ")), (kk.at / 60.0).floor() as i64);
        } else {
            n = display_name(&n);
            let x = norm(&n);
            k = if x.is_empty() { n.to_lowercase() } else { x };
        }
        let (g, gn, gkids) = group_ix
            .entry(e.group.clone())
            .or_insert_with(|| {
                groups.push(e.group.clone());
                let gn = norm(&e.group);
                let kids = KIDS.iter().any(|w| gn.contains(w));
                ((groups.len() - 1) as u32, gn, kids)
            })
            .clone();
        if let Some(&ix) = merge.get(&(k.clone(), g)) {
            let c = &mut channels[ix as usize];
            if c.urls.contains(&e.url) {
                return;
            }
            let rank = source_rank(&e.url);
            let at = c.urls.iter().position(|u| source_rank(u) > rank).unwrap_or(c.urls.len());
            c.urls.insert(at, e.url.clone());
            let same_ref = e.referer.as_deref().unwrap_or("") == c.referer.as_deref().unwrap_or("");
            let same_ua = e.ua.as_deref().unwrap_or("") == c.ua.as_deref().unwrap_or("");
            if !same_ref || !same_ua {
                c.hdr.push((e.url.clone(), e.referer.clone().unwrap_or_default(), e.ua.clone().unwrap_or_default()));
            }
            return;
        }
        let path = path_of(&e.url);
        let ext = ext_of_path(&path);
        let kids = gkids || is_kids("", &k);
        let ch = Channel {
            num: e.attrs.get("tvg-chno").filter(|x| !x.is_empty()).cloned().unwrap_or_else(|| index.to_string()),
            logo: e.attrs.get("tvg-logo").filter(|x| x.starts_with("http")).cloned(),
            tid: e.attrs.get("tvg-id").filter(|x| !x.is_empty()).cloned(),
            radio: is_radio(&e.attrs, &gn, &ext),
            vod: is_vod_path(&path),
            kids,
            urls: vec![e.url],
            referer: e.referer.filter(|x| !x.is_empty()),
            ua: e.ua.filter(|x| !x.is_empty()),
            hdr: Vec::new(),
            kick: kick.as_ref().map(|k| k.at).unwrap_or(0.0),
            dur: minutes,
            k: k.clone(),
            n,
            g,
        };
        merge.insert((k, g), channels.len() as u32);
        channels.push(ch);
    };
    let mut buf = Vec::with_capacity(4096);
    let mut input = input;
    loop {
        buf.clear();
        match input.read_until(b'\n', &mut buf) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        let line = String::from_utf8_lossy(&buf);
        if let Some(e) = r.line(line.trim_end_matches(['\r', '\n'])) {
            add(e, &mut channels, &mut groups);
        }
    }
    let mut by_key = HashMap::with_capacity(channels.len());
    for (i, c) in channels.iter().enumerate() {
        by_key.entry(c.k.clone()).or_insert(i as u32);
    }
    Loaded { list_id: list_id.into(), channels, groups, has_matches, epg: r.epg, entries, saw_extinf: r.saw_extinf, by_key }
}

// ======================================================================================================================
// Lịch phát sóng (XMLTV)
// ======================================================================================================================

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Programme {
    pub s: f64,
    pub e: f64,
    pub t: String,
}

#[derive(Default, Serialize, Deserialize)]
pub struct Guide {
    pub list: String,
    pub src: String,
    pub fetched: i64,
    pub prog: HashMap<String, Vec<Programme>>,
}

impl Guide {
    pub fn programmes(&self, c: &Channel) -> &[Programme] {
        for k in c.guide_keys() {
            if let Some(p) = self.prog.get(&k) {
                if !p.is_empty() {
                    return p;
                }
            }
        }
        &[]
    }
}

fn xml_unescape(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let Some(semi) = rest.find(';').filter(|&j| j < 12) else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let ent = &rest[1..semi];
        let ch = match ent {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ if ent.starts_with("#x") || ent.starts_with("#X") => u32::from_str_radix(&ent[2..], 16).ok().and_then(char::from_u32),
            _ if ent.starts_with('#') => ent[1..].parse::<u32>().ok().and_then(char::from_u32),
            _ => None,
        };
        match ch {
            Some(c) => {
                out.push(c);
                rest = &rest[semi + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// Giá trị thuộc tính `name="…"` (hoặc '…') trong thẻ XML.
fn xml_attr(tag: &str, name: &str) -> Option<String> {
    let b = tag.as_bytes();
    let mut from = 0;
    while let Some(i) = tag[from..].find(name).map(|x| x + from) {
        let before_ok = i == 0 || b[i - 1].is_ascii_whitespace();
        let mut j = i + name.len();
        while j < b.len() && b[j].is_ascii_whitespace() {
            j += 1;
        }
        if before_ok && j < b.len() && b[j] == b'=' {
            j += 1;
            while j < b.len() && b[j].is_ascii_whitespace() {
                j += 1;
            }
            if j < b.len() && (b[j] == b'"' || b[j] == b'\'') {
                let q = b[j];
                let end = tag[j + 1..].find(q as char)? + j + 1;
                return Some(xml_unescape(&tag[j + 1..end]));
            }
        }
        from = i + name.len();
    }
    None
}

/// Đọc XMLTV từng thẻ (không giữ cả tệp): chỉ chương trình của kênh có tvg-id trong `tids` hoặc tên chuẩn hoá (display-name)
/// trong `keys`, từ `from` tới `to`. Trả khoá → chương trình (đã xếp theo giờ).
pub fn parse_xmltv(input: impl BufRead, tids: &HashSet<String>, keys: &HashSet<String>, from: f64, to: f64) -> HashMap<String, Vec<Programme>> {
    let mut input = input;
    let mut out: HashMap<String, Vec<Programme>> = HashMap::new();
    let mut alias: HashMap<String, Option<String>> = HashMap::new();
    let mut chan: Option<String> = None;
    let mut prog: Option<(String, f64, Option<f64>)> = None;
    let mut title: Option<String> = None;
    let mut want_text: u8 = 0; // 1 = display-name, 2 = title
    let mut text = Vec::new();
    let mut tag = Vec::new();
    loop {
        text.clear();
        match input.read_until(b'<', &mut text) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        if text.last() == Some(&b'<') {
            text.pop();
        }
        tag.clear();
        match input.read_until(b'>', &mut tag) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        // Chú thích có thể chứa '>': đọc tới hết «-->»
        if tag.starts_with(b"!--") {
            while !tag.ends_with(b"-->") {
                match input.read_until(b'>', &mut tag) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
            }
            continue;
        }
        let t = String::from_utf8_lossy(&tag);
        let t = t.trim_end_matches('>');
        let closing = t.starts_with('/');
        let name_end = t.find(|c: char| c.is_whitespace() || c == '/').unwrap_or(t.len());
        let name = if closing { t[1..].trim() } else { &t[..name_end] };
        if want_text != 0 && closing {
            let s = xml_unescape(String::from_utf8_lossy(&text).trim());
            if want_text == 1 && name == "display-name" {
                if let Some(id) = &chan {
                    if alias.get(id).map(|a| a.is_none()).unwrap_or(true) {
                        let n = norm(&s);
                        let v = if tids.contains(id) {
                            Some(id.clone())
                        } else if !n.is_empty() && keys.contains(&n) {
                            Some(format!("n:{n}"))
                        } else {
                            None
                        };
                        alias.insert(id.clone(), v);
                    }
                }
            } else if want_text == 2 && name == "title" && title.is_none() {
                title = Some(s);
            }
            want_text = 0;
            continue;
        }
        if closing {
            match name {
                "channel" => chan = None,
                "programme" => {
                    if let Some((key, s, e)) = prog.take() {
                        let t = title.take().filter(|x| !x.is_empty()).unwrap_or_else(|| "(không tên)".into());
                        out.entry(key).or_default().push(Programme { s, e: e.unwrap_or(s + 1800.0), t });
                    }
                    title = None;
                }
                _ => {}
            }
            continue;
        }
        match name {
            "channel" => chan = xml_attr(t, "id"),
            "display-name" if chan.is_some() => want_text = 1,
            "programme" => {
                prog = None;
                title = None;
                let Some(cid) = xml_attr(t, "channel") else { continue };
                let key = match alias.get(&cid) {
                    Some(k) => k.clone(),
                    None => {
                        let k = if tids.contains(&cid) { Some(cid.clone()) } else { None };
                        alias.insert(cid.clone(), k.clone());
                        k
                    }
                };
                let Some(key) = key else { continue };
                let Some(s) = xml_attr(t, "start").and_then(|x| xmltv_time(&x)) else { continue };
                let e = xml_attr(t, "stop").and_then(|x| xmltv_time(&x));
                let ok = s <= to && match e {
                    Some(e) => e >= from,
                    None => s >= from,
                };
                if ok {
                    prog = Some((key, s, e));
                }
            }
            "title" if prog.is_some() && title.is_none() => want_text = 2,
            _ => {}
        }
    }
    for v in out.values_mut() {
        v.sort_by(|a, b| a.s.partial_cmp(&b.s).unwrap_or(std::cmp::Ordering::Equal));
    }
    out
}

// ======================================================================================================================
// Danh sách / trạng thái
// ======================================================================================================================

/// Danh sách kênh người xem đã thêm (địa chỉ hoặc tệp).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct IptvList {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub src: Option<String>,
    #[serde(default)]
    pub count: u32,
    #[serde(default)]
    pub updated: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub epg: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub err: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sig: Option<String>,
}

#[derive(Default)]
struct State {
    loaded: Option<Arc<Loaded>>,
    guide: Option<Arc<Guide>>,
    loading: bool,
    guide_loading: bool,
    status: Option<String>,
    last_try: i64,
    version: u64,
    filter: Option<(String, u64, Arc<Vec<u32>>)>,
}

static STATE: LazyLock<Mutex<State>> = LazyLock::new(|| Mutex::new(State::default()));

fn state() -> std::sync::MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(|e| e.into_inner())
}

fn changed(data: bool) {
    let mut s = state();
    if data {
        s.version += 1;
        s.filter = None;
    }
}

fn set_status(st: Option<String>) {
    state().status = st;
}

fn dir() -> PathBuf {
    let d = prefs::data_dir().join("iptv");
    let _ = std::fs::create_dir_all(d.join("files"));
    d
}

fn raw_file(l: &IptvList) -> PathBuf {
    match &l.file {
        Some(f) => dir().join("files").join(f),
        None => dir().join(format!("{}.m3u", l.id)),
    }
}

pub fn lists() -> Vec<IptvList> {
    prefs::get::<Vec<IptvList>>("iptv_lists").unwrap_or_default()
}

fn save_lists(l: &[IptvList]) {
    prefs::set("iptv_lists", Some(l));
}

fn update_list(id: &str, f: impl FnOnce(&mut IptvList)) {
    let mut l = lists();
    if let Some(x) = l.iter_mut().find(|x| x.id == id) {
        f(x);
    }
    save_lists(&l);
}

pub fn active_list() -> Option<IptvList> {
    let l = lists();
    let a = prefs::get::<String>("iptv_active");
    l.iter().find(|x| Some(&x.id) == a.as_ref()).cloned().or_else(|| l.first().cloned())
}

pub fn set_active(id: Option<&str>) {
    prefs::set("iptv_active", id);
    let mut s = state();
    s.loaded = None;
    s.guide = None;
    s.version += 1;
    s.filter = None;
}

pub fn add_list(input: &str, name: Option<&str>) -> IptvList {
    let url = list_url(input);
    let name = name.map(str::trim).filter(|x| !x.is_empty()).map(String::from).unwrap_or_else(|| name_from_url(&url));
    let l = IptvList { id: format!("l{}", now_ms()), name, url: Some(url), ..Default::default() };
    let mut all = lists();
    all.push(l.clone());
    save_lists(&all);
    set_active(Some(&l.id));
    l
}

/// Địa chỉ danh sách: thiếu `http(s)://` thì thêm `http://` (như bản Legacy / bản tivi).
fn list_url(input: &str) -> String {
    let url = input.trim();
    let lower = url.to_ascii_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") {
        url.to_string()
    } else {
        format!("http://{url}")
    }
}

/// Khoá so trùng địa chỉ danh sách: bỏ `http(s)://` và dấu `/` cuối, tên miền chữ thường (đường dẫn giữ nguyên — link rút gọn
/// phân biệt chữ hoa / thường).
pub fn list_url_key(url: &str) -> String {
    let u = url.trim();
    let lower = u.to_ascii_lowercase();
    let rest = if lower.starts_with("https://") {
        &u[8..]
    } else if lower.starts_with("http://") {
        &u[7..]
    } else {
        u
    };
    let (host, path) = rest.split_once('/').map(|(h, p)| (h, format!("/{p}"))).unwrap_or((rest, String::new()));
    format!("{}{}", host.to_ascii_lowercase(), path.trim_end_matches('/'))
}

/// Tách nhiều địa chỉ danh sách dán một lần — mỗi dòng (hoặc mỗi chữ cách nhau) một địa chỉ. Bỏ dòng trống, dòng chú thích `#`,
/// chữ không giống địa chỉ (không có dấu chấm); thiếu `http(s)://` thì thêm; bỏ trùng, giữ thứ tự.
pub fn split_urls(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        for tok in line.split_whitespace() {
            let t = tok.trim_matches(|c: char| matches!(c, '"' | '\'' | '<' | '>' | ',' | ';' | '(' | ')'));
            if t.len() < 4 || !t.contains('.') || t.starts_with('.') || t.ends_with('.') {
                continue;
            }
            let u = list_url(t);
            let k = list_url_key(&u);
            if !out.iter().any(|o| list_url_key(o) == k) {
                out.push(u);
            }
        }
    }
    out
}

/// Kết quả thêm nhiều danh sách một lần.
#[derive(Debug, Clone, Default, Serialize)]
pub struct AddMany {
    /// Danh sách vừa thêm (theo thứ tự dán)
    pub added: Vec<IptvList>,
    /// Số địa chỉ đã có sẵn trong app (bỏ qua)
    pub existing: usize,
}

/// Thêm nhiều danh sách cùng lúc (địa chỉ tách bằng `split_urls`). Địa chỉ đã có thì bỏ qua. Danh sách đầu tiên vừa thêm thành
/// danh sách đang dùng (các danh sách khác tải khi được chọn). Tên: một danh sách thì dùng `name`; nhiều thì «name 1», «name 2»…;
/// không có tên thì đặt theo địa chỉ.
pub fn add_lists(text: &str, name: Option<&str>) -> AddMany {
    let mut all = lists();
    let mut res = AddMany::default();
    let fresh: Vec<String> = split_urls(text)
        .into_iter()
        .filter(|u| {
            let k = list_url_key(u);
            let dup = all.iter().any(|l| l.url.as_deref().is_some_and(|x| list_url_key(x) == k));
            if dup {
                res.existing += 1;
            }
            !dup
        })
        .collect();
    let name = name.map(str::trim).filter(|x| !x.is_empty());
    let mut stamp = now_ms();
    for (i, url) in fresh.iter().enumerate() {
        let nm = match name {
            Some(n) if fresh.len() == 1 => n.to_string(),
            Some(n) => format!("{n} {}", i + 1),
            None => name_from_url(url),
        };
        // mã riêng cho từng danh sách (cùng một mili-giây)
        while all.iter().any(|l| l.id == format!("l{stamp}")) {
            stamp += 1;
        }
        let l = IptvList { id: format!("l{stamp}"), name: nm, url: Some(url.clone()), ..Default::default() };
        stamp += 1;
        all.push(l.clone());
        res.added.push(l);
    }
    if let Some(first) = res.added.first() {
        save_lists(&all);
        set_active(Some(&first.id));
    }
    res
}

/// Thêm danh sách từ tệp M3U trên máy: chép vào `iptv/files/`.
pub fn add_file(path: &str, name: Option<&str>) -> Result<IptvList> {
    let p = PathBuf::from(path);
    let mut head = vec![0u8; 64 * 1024];
    let n = std::fs::File::open(&p).and_then(|mut f| f.read(&mut head)).map_err(|e| Error::App(format!("Không đọc được tệp: {e}")))?;
    if n == 0 {
        return Err(Error::App("Tệp trống.".into()));
    }
    let h = String::from_utf8_lossy(&head[..n]);
    if !h.contains("#EXTINF") && !h.contains("http") {
        return Err(Error::App("Tệp không phải danh sách M3U (không có dòng #EXTINF / địa chỉ kênh nào).".into()));
    }
    let id = format!("l{}", now_ms());
    let file = format!("{id}.m3u");
    std::fs::copy(&p, dir().join("files").join(&file)).map_err(|e| Error::App(format!("Không chép được tệp: {e}")))?;
    let src = p.file_name().map(|x| x.to_string_lossy().to_string());
    let name = name
        .map(str::trim)
        .filter(|x| !x.is_empty())
        .map(String::from)
        .unwrap_or_else(|| name_from_file(src.as_deref().unwrap_or("danh-sach.m3u")));
    let l = IptvList { id: id.clone(), name, file: Some(file), src, ..Default::default() };
    let mut all = lists();
    all.push(l.clone());
    save_lists(&all);
    set_active(Some(&id));
    crate::log::d("IPTV", &format!("thêm danh sách từ tệp {path} → {id}"));
    Ok(l)
}

pub fn rename_list(id: &str, name: &str) {
    if !name.trim().is_empty() {
        update_list(id, |l| l.name = name.trim().to_string());
        changed(false);
    }
}

pub fn remove_list(id: &str) {
    let all = lists();
    let Some(l) = all.iter().find(|x| x.id == id).cloned() else { return };
    let rest: Vec<IptvList> = all.into_iter().filter(|x| x.id != id).collect();
    save_lists(&rest);
    let _ = std::fs::remove_file(raw_file(&l));
    let _ = std::fs::remove_file(dir().join(format!("epg-{id}.json")));
    if prefs::get::<String>("iptv_active").as_deref() == Some(id) || active_list().map(|x| x.id) != state().loaded.as_ref().map(|x| x.list_id.clone()) {
        set_active(rest.first().map(|x| x.id.as_str()));
    } else {
        changed(true);
    }
}

/// Trạng thái cho giao diện: đang tải / dòng trạng thái / lần đổi dữ liệu (giao diện hỏi lại khi khác).
pub fn status() -> Value {
    let s = state();
    json!({"loading": s.loading, "guideLoading": s.guide_loading, "status": s.status, "version": s.version,
           "active": active_list(), "loaded": s.loaded.as_ref().map(|l| l.list_id.clone())})
}

pub fn loading() -> bool {
    let s = state();
    s.loading || s.guide_loading
}

fn loaded_for(id: &str) -> Option<Arc<Loaded>> {
    state().loaded.clone().filter(|l| l.list_id == id)
}

/// Kênh của danh sách đang chọn: đã đọc thì trả luôn; chưa thì đọc tệp đã lưu (không tải mạng). None = chưa có tệp.
pub async fn ensure_loaded() -> Option<Arc<Loaded>> {
    let l = active_list()?;
    if let Some(x) = loaded_for(&l.id) {
        return Some(x);
    }
    let path = raw_file(&l);
    if !path.exists() {
        return None;
    }
    let id = l.id.clone();
    let parsed = tokio::task::spawn_blocking(move || {
        let f = std::fs::File::open(&path).ok()?;
        Some(build(&id, open_maybe_gz(f), now_sec()))
    })
    .await
    .ok()
    .flatten()?;
    let arc = Arc::new(parsed);
    {
        let mut s = state();
        if active_list().map(|a| a.id) == Some(l.id.clone()) {
            s.loaded = Some(arc.clone());
            s.version += 1;
            s.filter = None;
        }
    }
    load_guide_cache(&l.id);
    Some(arc)
}

fn open_maybe_gz(f: std::fs::File) -> Box<dyn BufRead + Send> {
    let mut b = BufReader::with_capacity(64 * 1024, f);
    let gz = b.fill_buf().map(|x| x.len() >= 2 && x[0] == 0x1f && x[1] == 0x8b).unwrap_or(false);
    if gz {
        Box::new(BufReader::with_capacity(64 * 1024, flate2::bufread::MultiGzDecoder::new(b)))
    } else {
        Box::new(b)
    }
}

/// Danh sách cũ quá bao lâu thì tải lại (ms).
fn max_age(l: Option<&Loaded>) -> i64 {
    let Some(l) = l.filter(|l| l.has_matches) else { return LIST_MAX_AGE };
    let now = now_sec();
    let waiting =
        l.channels.iter().any(|c| c.kick > 0.0 && c.nolink() && now >= c.kick - MATCH_EARLY && now < c.kick + c.dur as f64 * 60.0);
    if waiting { WAITING_LIST_MAX_AGE } else { MATCH_LIST_MAX_AGE }
}

/// Màn Truyền hình đang mở (mỗi 30 giây / lúc quay lại): tải lại nếu đã quá hạn; vừa tải hỏng thì 3 phút sau mới thử lại.
pub async fn auto_refresh() {
    let Some(l) = active_list() else { return };
    if l.file.is_some() || loading() || now_ms() - state().last_try < AUTO_RETRY_GAP {
        return;
    }
    let have = ensure_loaded().await;
    if have.is_some() && now_ms() - l.updated < max_age(have.as_deref()) {
        return;
    }
    crate::log::d("IPTV", &format!("tự làm mới danh sách «{}»", l.name));
    let _ = refresh(false).await;
}

/// Tải lại danh sách nếu cũ hơn `seconds` (đang tải thì chờ xong) — trình phát tìm link mới.
pub async fn refresh_if_older_than(seconds: i64) -> Result<()> {
    for _ in 0..600 {
        if !state().loading {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
    let old = now_ms() - active_list().map(|l| l.updated).unwrap_or(0) > seconds * 1000;
    if old { refresh(true).await } else { Ok(()) }
}

/// Tải danh sách đang chọn (force: bỏ qua bản còn mới), rồi lịch nếu cũ. Lỗi: lý do (đã ghi vào danh sách).
pub async fn refresh(force: bool) -> Result<()> {
    let Some(l) = active_list() else { return Err(Error::App("Chưa có danh sách kênh".into())) };
    {
        let mut s = state();
        if s.loading {
            return Ok(());
        }
        s.loading = true;
    }
    let r = refresh_inner(&l, force).await;
    {
        let mut s = state();
        s.loading = false;
        s.status = None;
        s.version += 1;
        s.filter = None;
    }
    match &r {
        Ok(()) => {
            update_list(&l.id, |x| x.err = None);
            let _ = refresh_guide(false).await;
        }
        Err(e) => {
            let why = crate::util::friendly(e);
            crate::log::d("IPTV", &format!("tải danh sách «{}» lỗi: {why}", l.name));
            update_list(&l.id, |x| x.err = Some(why));
        }
    }
    r
}

async fn refresh_inner(l: &IptvList, force: bool) -> Result<()> {
    let have = ensure_loaded().await;
    let fresh = l.file.is_some() || now_ms() - l.updated < max_age(have.as_deref());
    if !force && fresh && have.is_some() && l.updated > 0 {
        return Ok(());
    }
    state().last_try = now_ms();
    let t0 = now_ms();
    let path = raw_file(l);
    let mut sig = None;
    // Tệp sẽ đọc: danh sách theo địa chỉ thì đọc bản vừa tải (.part) trước — chỉ thay tệp cũ khi bản mới có kênh (cổng đăng
    // nhập Wi‑Fi / trang «hết hạn» trả HTML 200 thì giữ nguyên danh sách đang dùng được)
    let mut src = path.clone();
    if let Some(url) = &l.url {
        set_status(Some("Đang tải danh sách kênh…".into()));
        let part = dir().join(format!("{}.part", l.id));
        let (crc, size) = fetch_to(url, &[], &part, |done| {
            set_status(Some(format!("Đang tải danh sách kênh… {} MB", done >> 20)));
        })
        .await?;
        let s = format!("{PARSE_VERSION}:{crc}:{size}");
        if Some(&s) == l.sig.as_ref() && have.is_some() && path.exists() {
            let _ = std::fs::remove_file(&part);
            update_list(&l.id, |x| x.updated = now_ms());
            crate::log::d("IPTV", &format!("danh sách «{}» không đổi từ lần trước ({} ms)", l.name, now_ms() - t0));
            return Ok(());
        }
        // Danh sách vừa bị xoá trong lúc tải: bỏ tệp tải về (không để lại tệp mồ côi)
        if !lists().iter().any(|x| x.id == l.id) {
            let _ = std::fs::remove_file(&part);
            return Ok(());
        }
        src = part;
        sig = Some(s);
    }
    set_status(Some("Đang đọc danh sách kênh…".into()));
    let id = l.id.clone();
    let p2 = src.clone();
    let parsed = tokio::task::spawn_blocking(move || -> std::io::Result<Loaded> {
        let f = std::fs::File::open(&p2)?;
        Ok(build(&id, open_maybe_gz(f), now_sec()))
    })
    .await
    .map_err(|e| Error::App(e.to_string()))
    .and_then(|r| r.map_err(|e| Error::App(format!("Không đọc được danh sách: {e}"))));
    let drop_part = || {
        if src != path {
            let _ = std::fs::remove_file(&src);
        }
    };
    let parsed = match parsed {
        Ok(p) => p,
        Err(e) => {
            drop_part();
            return Err(e);
        }
    };
    if parsed.channels.is_empty() {
        drop_part();
        let why = if parsed.saw_extinf { "Danh sách không có kênh nào." } else { "Tệp tải về không phải danh sách M3U." };
        return Err(Error::App(why.into()));
    }
    if src != path {
        std::fs::rename(&src, &path).map_err(|e| Error::App(format!("Không ghi được danh sách: {e}")))?;
    }
    crate::log::d("IPTV", &format!(
        "danh sách «{}» — {} mục → {} kênh, lịch {} ({} ms)",
        l.name,
        parsed.entries,
        parsed.channels.len(),
        parsed.epg.as_deref().unwrap_or("không có"),
        now_ms() - t0
    ));
    let count = parsed.channels.len() as u32;
    let epg = parsed.epg.clone();
    // Trong lúc tải người dùng đã chọn danh sách khác: không đè danh sách đang dùng (lần sau đọc lại từ tệp)
    if active_list().map(|a| a.id).as_deref() == Some(l.id.as_str()) {
        let mut s = state();
        s.loaded = Some(Arc::new(parsed));
    }
    update_list(&l.id, |x| {
        x.count = count;
        x.updated = now_ms();
        x.epg = epg;
        if sig.is_some() {
            x.sig = sig;
        }
    });
    Ok(())
}

fn direct_client() -> reqwest::Client {
    reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::limited(10))
        .connect_timeout(std::time::Duration::from_secs(15))
        .user_agent(crate::http::user_agent())
        .build()
        .expect("reqwest")
}

/// Tải `url` vào tệp `to`, trả (CRC32, cỡ). Qua mạng của app (DNS mã hoá, vượt chặn, proxy); lỗi kết nối (không phải mã lỗi
/// HTTP) mà không bật proxy thì thử mạng của máy — DNS mã hoá chỉ lấy một địa chỉ của tên miền, địa chỉ đó chết thì hỏng
/// (gặp trên tivi 16/11 với dịch vụ rút gọn link; bản Legacy cũng thử lại bằng mạng của máy).
pub async fn fetch_to(url: &str, headers: &[(&str, &str)], to: &std::path::Path, progress: impl Fn(u64)) -> Result<(u32, u64)> {
    use futures::StreamExt;
    use std::io::Write;
    let send = |c: reqwest::Client| {
        let mut rq = c.get(url).timeout(std::time::Duration::from_secs(900));
        for (k, v) in headers {
            rq = rq.header(*k, *v);
        }
        rq.send()
    };
    let resp = match send(crate::http::client()).await {
        Ok(r) => r,
        Err(e) if !e.is_status() && crate::net::proxy().is_none() && crate::net::ss().is_none() => {
            crate::log::d("IPTV", &format!("mạng của app lỗi với {url} ({e}) — thử mạng của máy"));
            send(direct_client()).await?
        }
        Err(e) => return Err(e.into()),
    };
    let code = resp.status().as_u16();
    if code >= 400 {
        return Err(Error::Http(code));
    }
    let mut f = std::fs::File::create(to)?;
    let mut crc = crc32fast::Hasher::new();
    let mut total = 0u64;
    let mut shown = 0u64;
    let mut s = resp.bytes_stream();
    while let Some(chunk) = s.next().await {
        let chunk = chunk?;
        f.write_all(&chunk)?;
        crc.update(&chunk);
        total += chunk.len() as u64;
        if total - shown >= 2 << 20 {
            shown = total;
            progress(total);
        }
    }
    f.flush()?;
    Ok((crc.finalize(), total))
}

// ---- Lịch ----

pub fn epg_override() -> Option<String> {
    prefs::get::<String>("iptv_epg_url").filter(|x| !x.trim().is_empty())
}

pub fn set_epg_override(url: Option<&str>) {
    prefs::set("iptv_epg_url", url.map(str::trim).filter(|x| !x.is_empty()));
}

pub fn epg_url() -> Option<String> {
    epg_override().or_else(|| active_list().and_then(|l| l.epg))
}

fn guide_file(id: &str) -> PathBuf {
    dir().join(format!("epg-{id}.json"))
}

fn load_guide_cache(id: &str) {
    if state().guide.as_ref().map(|g| g.list == id).unwrap_or(false) {
        return;
    }
    if let Some(g) = std::fs::read(guide_file(id)).ok().and_then(|d| serde_json::from_slice::<Guide>(&d).ok()) {
        let mut s = state();
        s.guide = Some(Arc::new(g));
        s.version += 1;
    }
}

pub fn guide() -> Option<Arc<Guide>> {
    let id = active_list()?.id;
    state().guide.clone().filter(|g| g.list == id)
}

pub async fn refresh_guide(force: bool) -> Result<()> {
    let Some(url) = epg_url() else { return Err(Error::App("Danh sách không ghi địa chỉ lịch phát sóng (EPG)".into())) };
    let Some(l) = active_list() else { return Err(Error::App("Chưa có danh sách kênh".into())) };
    let Some(loaded) = ensure_loaded().await else { return Err(Error::App("Chưa tải danh sách kênh".into())) };
    load_guide_cache(&l.id);
    if let Some(g) = guide() {
        if !force && g.src == url && now_ms() - g.fetched < GUIDE_MAX_AGE {
            return Ok(());
        }
    }
    {
        let mut s = state();
        if s.guide_loading {
            return Ok(());
        }
        s.guide_loading = true;
        s.status = Some("Đang tải lịch phát sóng…".into());
    }
    let t0 = now_ms();
    let raw = dir().join(format!("epg-{}.download", l.id));
    let r = async {
        fetch_to(&url, &[], &raw, |_| {}).await?;
        let tids: HashSet<String> = loaded.channels.iter().filter_map(|c| c.tid.clone()).collect();
        let keys: HashSet<String> = loaded.channels.iter().map(|c| c.k.clone()).collect();
        let raw2 = raw.clone();
        let prog = tokio::task::spawn_blocking(move || -> std::io::Result<HashMap<String, Vec<Programme>>> {
            let now = now_sec();
            let f = std::fs::File::open(&raw2)?;
            Ok(parse_xmltv(open_maybe_gz(f), &tids, &keys, now - 24.0 * 3600.0, now + 48.0 * 3600.0))
        })
        .await
        .map_err(|e| Error::App(e.to_string()))??;
        let g = Guide { list: l.id.clone(), src: url.clone(), fetched: now_ms(), prog };
        if let Ok(d) = serde_json::to_vec(&g) {
            let _ = std::fs::write(guide_file(&l.id), d);
        }
        crate::log::d("IPTV", &format!("lịch {url} — {} kênh có lịch ({} ms)", g.prog.len(), now_ms() - t0));
        Ok::<Guide, Error>(g)
    }
    .await;
    let _ = std::fs::remove_file(&raw);
    let mut s = state();
    s.guide_loading = false;
    s.status = None;
    s.version += 1;
    match r {
        Ok(g) => {
            s.guide = Some(Arc::new(g));
            Ok(())
        }
        Err(e) => Err(e),
    }
}

// ======================================================================================================================
// Yêu thích / vừa xem / kênh hỏng / cài đặt
// ======================================================================================================================

fn own(key: &str) -> String {
    prefs::pk(&prefs::profile_id(), key)
}

pub fn favorite_keys() -> Vec<String> {
    prefs::get::<Vec<String>>(&own("iptv_favs")).unwrap_or_default()
}

pub fn set_favorite(key: &str, on: bool) {
    let mut f: Vec<String> = favorite_keys().into_iter().filter(|x| x != key).collect();
    if on {
        f.push(key.to_string());
    }
    prefs::set(&own("iptv_favs"), Some(f));
    changed(true);
}

/// Kênh vừa xem (mới nhất trước, tối đa 12): {k, n, logo, g, l (danh sách), radio}.
pub fn recent() -> Vec<Value> {
    prefs::get::<Vec<Value>>(&own("iptv_recent")).unwrap_or_default()
}

pub fn add_recent(c: &Channel, group: &str) {
    if prefs::get::<bool>(&own("private_mode")).unwrap_or(false) {
        return;
    }
    let mut item = json!({"k": c.k, "n": c.n, "g": group});
    if let Some(l) = active_list() {
        item["l"] = json!(l.id);
    }
    if let Some(logo) = &c.logo {
        item["logo"] = json!(logo);
    }
    if c.radio {
        item["radio"] = json!(true);
    }
    let mut r = vec![item];
    r.extend(recent().into_iter().filter(|x| x["k"].as_str() != Some(&c.k)).take(11));
    prefs::set(&own("iptv_recent"), Some(r));
}

fn bad_map() -> Map<String, Value> {
    prefs::get::<Map<String, Value>>("iptv_bad").unwrap_or_default()
}

pub fn bad_reason(url: &str) -> Option<String> {
    bad_map().get(url).and_then(|v| v.as_str()).map(String::from)
}

pub fn mark_bad(url: &str, reason: &str) {
    let mut m = bad_map();
    if m.len() > 500 {
        m.clear();
    }
    m.insert(url.into(), json!(reason));
    prefs::set("iptv_bad", Some(m));
    changed(true);
}

pub fn clear_bad() {
    prefs::set::<Value>("iptv_bad", None);
    changed(true);
}

pub fn clear_bad_for(key: &str) {
    let Some(l) = state().loaded.clone() else { return };
    let Some((_, c)) = l.by_key(key) else { return };
    let mut m = bad_map();
    for u in &c.urls {
        m.remove(u);
    }
    prefs::set("iptv_bad", Some(m));
    changed(true);
}

fn channel_bad(c: &Channel, bad: &Map<String, Value>) -> Option<String> {
    if c.urls.is_empty() || !c.urls.iter().all(|u| bad.contains_key(u)) {
        return None;
    }
    bad.get(&c.urls[0]).and_then(|v| v.as_str()).map(String::from)
}

/// Ẩn kênh mà mọi nguồn đều đã ghi «máy không giải mã được» (lỗi mạng thoáng qua không ghi).
pub fn hide_bad() -> bool {
    prefs::get::<bool>("iptv_hide_bad").unwrap_or(true)
}

pub fn auto_source() -> bool {
    prefs::get::<bool>("iptv_auto_source").unwrap_or(true)
}

// ======================================================================================================================
// Lọc / trang kênh cho giao diện
// ======================================================================================================================

/// Bộ lọc của lưới / bảng kênh: nhóm (số thứ tự trong danh sách; None = tất cả), chỉ yêu thích, chữ tìm (tên hoặc số kênh).
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Filter {
    #[serde(default)]
    pub group: Option<u32>,
    #[serde(default)]
    pub favs: bool,
    #[serde(default)]
    pub q: String,
}

fn filtered(l: &Arc<Loaded>, f: &Filter) -> Arc<Vec<u32>> {
    let kids = prefs::kids();
    let hide = hide_bad();
    // Kênh yêu thích là của từng người xem (đổi người xem / đồng bộ không tăng version): khoá có cả người xem và danh
    // sách yêu thích, không thì hàng «Kênh yêu thích» của người mới hiện kênh của người trước
    let fav_list = if f.favs { favorite_keys() } else { Vec::new() };
    let key = format!("{}|{:?}|{}|{}|{kids}|{hide}|{}|{}", l.list_id, f.group, f.favs, f.q, prefs::profile_id(), fav_list.join("\u{1}"));
    let version = state().version;
    if let Some((k, v, ids)) = &state().filter {
        if *k == key && *v == version {
            return ids.clone();
        }
    }
    let favs: HashSet<String> = fav_list.into_iter().collect();
    let bad = if hide { bad_map() } else { Map::new() };
    let q = f.q.trim();
    let nq = norm(q);
    let mut ids: Vec<u32> = l
        .channels
        .iter()
        .enumerate()
        .filter(|(_, c)| {
            f.group.map(|g| c.g == g).unwrap_or(true) &&
                (!f.favs || favs.contains(&c.k)) &&
                (!kids || c.kids) &&
                (!hide || channel_bad(c, &bad).is_none()) &&
                (q.is_empty() || (!nq.is_empty() && c.k.contains(&nq)) || c.num == q)
        })
        .map(|(i, _)| i as u32)
        .collect();
    // Danh sách có trận: đang đá (có link trước) → sắp đá (sớm trước) → kênh thường → đã xong (mới xong trước)
    if l.has_matches {
        let now = now_sec();
        let rank = |c: &Channel| match match_state(c.kick, c.dur, now) {
            Match::Live => {
                if c.nolink() { 1 } else { 0 }
            }
            Match::Later | Match::Soon => 2,
            Match::None => 3,
            Match::Over => 4,
        };
        ids.sort_by(|&a, &b| {
            let (ca, cb) = (&l.channels[a as usize], &l.channels[b as usize]);
            let (ra, rb) = (rank(ca), rank(cb));
            let ka = if ra == 4 { -ca.kick } else { ca.kick };
            let kb = if rb == 4 { -cb.kick } else { cb.kick };
            ra.cmp(&rb).then(ka.partial_cmp(&kb).unwrap_or(std::cmp::Ordering::Equal)).then(a.cmp(&b))
        });
    }
    let ids = Arc::new(ids);
    state().filter = Some((key, version, ids.clone()));
    ids
}

/// Một kênh cho giao diện (kèm chương trình đang phát / kế tiếp, trạng thái trận, dấu hỏng, yêu thích).
pub fn view(l: &Loaded, ix: u32, guide: Option<&Guide>, favs: &HashSet<String>, bad: &Map<String, Value>, full: bool) -> Value {
    let c = &l.channels[ix as usize];
    let now = now_sec();
    let mut v = json!({
        "id": ix, "k": c.k, "n": c.n, "g": l.groups.get(c.g as usize).cloned().unwrap_or_default(), "num": c.num,
        "logo": c.logo, "radio": c.radio, "vod": c.vod, "kick": c.kick, "dur": c.dur, "nolink": c.nolink(),
        "sources": c.urls.len(), "fav": favs.contains(&c.k), "match": match_state(c.kick, c.dur, now),
        "matchLine": match_line(c.kick, c.dur, c.nolink(), now), "bad": channel_bad(c, bad),
    });
    if let Some(g) = guide {
        let p = g.programmes(c);
        v["now"] = json!(p.iter().find(|x| x.s <= now && now < x.e));
        v["next"] = json!(p.iter().find(|x| x.s > now));
        if full {
            v["programmes"] = json!(p);
        }
    }
    if full {
        let src: Vec<Value> = c
            .urls
            .iter()
            .map(|u| {
                let (r, a) = c.headers_for(u);
                json!({"url": u, "referer": r, "ua": a, "bad": bad.get(u)})
            })
            .collect();
        v["urls"] = json!(src);
        v["tid"] = json!(c.tid);
    }
    v
}

/// Nhóm có kênh (theo hồ sơ trẻ em / ẩn kênh hỏng) + số kênh tất cả / yêu thích.
pub async fn groups() -> Value {
    let Some(l) = ensure_loaded().await else { return json!({"groups": [], "total": 0, "favs": 0}) };
    let all = filtered(&l, &Filter::default());
    let mut counts = vec![0u32; l.groups.len()];
    for &i in all.iter() {
        counts[l.channels[i as usize].g as usize] += 1;
    }
    let favs = filtered(&l, &Filter { favs: true, ..Default::default() }).len();
    let groups: Vec<Value> = l
        .groups
        .iter()
        .enumerate()
        .filter(|(i, _)| counts[*i] > 0)
        .map(|(i, n)| json!({"id": i, "name": n, "count": counts[i]}))
        .collect();
    json!({"groups": groups, "total": all.len(), "favs": favs, "list": l.list_id})
}

/// Một trang kênh của bộ lọc.
pub async fn page(f: &Filter, offset: usize, limit: usize) -> Value {
    let Some(l) = ensure_loaded().await else { return json!({"total": 0, "items": []}) };
    let ids = filtered(&l, f);
    let g = guide();
    let favs: HashSet<String> = favorite_keys().into_iter().collect();
    let bad = bad_map();
    let items: Vec<Value> =
        ids.iter().skip(offset).take(limit).map(|&i| view(&l, i, g.as_deref(), &favs, &bad, false)).collect();
    json!({"total": ids.len(), "items": items, "offset": offset})
}

/// Kênh ở vị trí `index` của bộ lọc (đủ nguồn + lịch) — trình phát.
pub async fn at(f: &Filter, index: usize) -> Value {
    let Some(l) = ensure_loaded().await else { return Value::Null };
    let ids = filtered(&l, f);
    let Some(&ix) = ids.get(index) else { return Value::Null };
    let favs: HashSet<String> = favorite_keys().into_iter().collect();
    let mut v = view(&l, ix, guide().as_deref(), &favs, &bad_map(), true);
    v["index"] = json!(index);
    v["total"] = json!(ids.len());
    v
}

/// Vị trí của kênh có khoá `key` (hoặc số kênh `num`) trong bộ lọc; -1 = không có.
pub async fn index_of(f: &Filter, key: Option<&str>, num: Option<&str>) -> i64 {
    let Some(l) = ensure_loaded().await else { return -1 };
    let ids = filtered(&l, f);
    ids.iter()
        .position(|&i| {
            let c = &l.channels[i as usize];
            key.map(|k| c.k == k).unwrap_or(false) || num.map(|n| c.num == n).unwrap_or(false)
        })
        .map(|p| p as i64)
        .unwrap_or(-1)
}

/// Ghi kênh vừa xem (trình phát phát được).
pub async fn played(key: &str) {
    let Some(l) = ensure_loaded().await else { return };
    if let Some((_, c)) = l.by_key(key) {
        add_recent(c, l.groups.get(c.g as usize).map(String::as_str).unwrap_or(""));
    }
}

// ======================================================================================================================
// Trang chủ: các hàng Truyền hình (Kênh vừa xem, Kênh yêu thích, Trận đang / sắp đá, Radio)
// ======================================================================================================================

/// Trận còn bao lâu nữa mới đá thì vẫn hiện ở hàng «Trận đang / sắp đá» của trang chủ.
const HOME_LIVE_AHEAD: f64 = 12.0 * 3600.0;

/// Ô kênh của hàng trang chủ: như ô lưới (`view`) + "l" (danh sách) + "frac" (tiến độ chương trình đang phát / trận đang đá,
/// 0…1; -1 = không có).
fn home_cell(l: &Loaded, ix: u32, g: Option<&Guide>, favs: &HashSet<String>, bad: &Map<String, Value>, now: f64) -> Value {
    let c = &l.channels[ix as usize];
    let mut v = view(l, ix, g, favs, bad, false);
    v["l"] = json!(l.list_id);
    let state = match_state(c.kick, c.dur, now);
    v["match"] = json!(state);
    v["matchLine"] = json!(match_line(c.kick, c.dur, c.nolink(), now));
    let frac = if state == Match::Live && c.dur > 0 {
        (now - c.kick) / (c.dur as f64 * 60.0)
    } else if let (Some(s), Some(e)) = (v["now"]["s"].as_f64(), v["now"]["e"].as_f64()) {
        (now - s) / (e - s).max(1.0)
    } else {
        -1.0
    };
    v["frac"] = json!(if frac < 0.0 { -1.0 } else { frac.min(1.0) });
    v
}

/// Các hàng Truyền hình của trang chủ từ danh sách đã đọc (hàm thuần — `home_rows` lấy dữ liệu của người xem rồi gọi):
/// - recent: kênh vừa xem đúng thứ tự — kênh của danh sách đang dùng thì như ô lưới (chương trình đang phát, trận), kênh của
///   danh sách khác (hoặc đã bỏ khỏi danh sách) thì như đã ghi lúc xem (k, n, logo, g, l, radio);
/// - favs: kênh yêu thích của danh sách đang dùng (theo thứ tự đánh dấu);
/// - live: trận đang đá (có link trước) rồi sắp đá trong 12 giờ (sớm trước);
/// - radio: đài vừa nghe trước, rồi các đài khác theo thứ tự danh sách.
/// Hồ sơ trẻ em: chỉ kênh thiếu nhi, không có live / radio. hide: bỏ kênh hỏng (như lưới khi bật «Ẩn kênh hỏng»).
#[allow(clippy::too_many_arguments)]
pub fn home_rows_of(
    l: &Loaded, g: Option<&Guide>, recent: &[Value], favs: &[String], kids: bool, hide: bool, bad: &Map<String, Value>, now: f64,
    limit: usize,
) -> Value {
    let favset: HashSet<String> = favs.iter().cloned().collect();
    let ok = |c: &Channel| (!kids || c.kids) && (!hide || channel_bad(c, bad).is_none());
    let cell = |ix: u32| home_cell(l, ix, g, &favset, bad, now);

    let mut rec = Vec::new();
    for r in recent {
        if rec.len() >= limit {
            break;
        }
        let k = r["k"].as_str().unwrap_or("");
        let same_list = r["l"].as_str().map(|x| x == l.list_id).unwrap_or(true);
        match l.by_key(k).filter(|_| same_list) {
            Some((ix, c)) if ok(c) => rec.push(cell(ix)),
            Some(_) => {}
            None if !kids => rec.push(r.clone()),
            None => {}
        }
    }

    let fav: Vec<Value> =
        favs.iter().filter_map(|k| l.by_key(k)).filter(|(_, c)| ok(c)).take(limit).map(|(ix, _)| cell(ix)).collect();

    let mut live: Vec<(u8, f64, u32)> = Vec::new();
    let mut radio: Vec<u32> = Vec::new();
    if !kids {
        for (i, c) in l.channels.iter().enumerate() {
            if c.kick <= 0.0 || !ok(c) {
                continue;
            }
            let rank = match match_state(c.kick, c.dur, now) {
                Match::Live => {
                    if c.nolink() { 1 } else { 0 }
                }
                Match::Soon => 2,
                Match::Later if c.kick - now <= HOME_LIVE_AHEAD => 2,
                _ => continue,
            };
            live.push((rank, c.kick, i as u32));
        }
        live.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal)).then(a.2.cmp(&b.2)));
        live.truncate(limit);

        let mut seen: HashSet<u32> = HashSet::new();
        for r in recent.iter().filter(|r| r["radio"].as_bool() == Some(true)) {
            let same_list = r["l"].as_str().map(|x| x == l.list_id).unwrap_or(true);
            if let Some((ix, c)) = r["k"].as_str().and_then(|k| l.by_key(k)).filter(|_| same_list) {
                if c.radio && ok(c) && radio.len() < limit && seen.insert(ix) {
                    radio.push(ix);
                }
            }
        }
        for (i, c) in l.channels.iter().enumerate() {
            if radio.len() >= limit {
                break;
            }
            if c.radio && ok(c) && seen.insert(i as u32) {
                radio.push(i as u32);
            }
        }
    }
    json!({
        "list": l.list_id,
        "recent": rec,
        "favs": fav,
        "live": live.iter().map(|x| cell(x.2)).collect::<Vec<_>>(),
        "radio": radio.iter().map(|&ix| cell(ix)).collect::<Vec<_>>(),
    })
}

/// Các hàng Truyền hình của trang chủ cho người xem đang dùng (xem `home_rows_of`). Danh sách đang dùng chưa đọc thì đọc tệp đã
/// lưu (không tải mạng; giao diện gọi không chặn rồi dựng lại); chưa có tệp thì chỉ có kênh vừa xem (như đã ghi). Không có
/// danh sách nào: mọi hàng rỗng. "loaded": danh sách đã đọc xong.
pub async fn home_rows(limit: usize) -> Value {
    let empty = json!({"recent": [], "favs": [], "live": [], "radio": [], "loaded": false});
    if active_list().is_none() {
        return empty;
    }
    let rec = recent();
    let Some(l) = ensure_loaded().await else {
        let mut v = empty;
        if !prefs::kids() {
            v["recent"] = json!(rec.into_iter().take(limit).collect::<Vec<_>>());
        }
        return v;
    };
    let g = guide();
    let mut v = home_rows_of(&l, g.as_deref(), &rec, &favorite_keys(), prefs::kids(), hide_bad(), &bad_map(), now_sec(), limit);
    v["loaded"] = json!(true);
    v
}

/// Như `home_rows` nhưng không đọc tệp (dựng trang chủ ngay, không chờ): danh sách chưa đọc thì "loaded": false và chỉ có kênh
/// vừa xem như đã ghi.
pub fn home_rows_now(limit: usize) -> Value {
    let empty = json!({"recent": [], "favs": [], "live": [], "radio": [], "loaded": false});
    let Some(a) = active_list() else { return empty };
    let rec = recent();
    let Some(l) = loaded_for(&a.id) else {
        let mut v = empty;
        if !prefs::kids() {
            v["recent"] = json!(rec.into_iter().take(limit).collect::<Vec<_>>());
        }
        return v;
    };
    let g = guide();
    let mut v = home_rows_of(&l, g.as_deref(), &rec, &favorite_keys(), prefs::kids(), hide_bad(), &bad_map(), now_sec(), limit);
    v["loaded"] = json!(true);
    v
}

// ======================================================================================================================
// Nhắc giờ phát / bóng lăn (giao diện hỏi `due` mỗi 15 giây khi app mở)
// ======================================================================================================================

fn reminders() -> Vec<Value> {
    prefs::get::<Vec<Value>>("iptv_reminders").unwrap_or_default()
}

/// Bật / tắt nhắc: `kick` = nhắc lúc bóng lăn (giờ trận), không thì «Nhắc tôi» 5 phút trước giờ phát `s`. true = vừa đặt.
pub fn toggle_reminder(key: &str, name: &str, title: &str, s: f64, kick: bool) -> bool {
    let all = reminders();
    let same = |r: &Value| r["k"].as_str() == Some(key) && r["kick"].as_bool().unwrap_or(false) == kick &&
        (kick || (r["s"].as_f64().unwrap_or(0.0) - s).abs() < 1.0);
    if all.iter().any(same) {
        prefs::set("iptv_reminders", Some(all.into_iter().filter(|r| !same(r)).collect::<Vec<_>>()));
        return false;
    }
    let at = if kick { (s * 1000.0) as i64 } else { (((s - 300.0) * 1000.0) as i64).max(now_ms() + 5000) };
    let mut v = all;
    v.push(json!({"k": key, "n": name, "t": title, "s": s, "at": at, "kick": kick}));
    prefs::set("iptv_reminders", Some(v));
    true
}

pub fn has_reminder(key: &str, s: Option<f64>, kick: bool) -> bool {
    reminders().iter().any(|r| {
        r["k"].as_str() == Some(key) && r["kick"].as_bool().unwrap_or(false) == kick &&
            (kick || s.map(|s| (r["s"].as_f64().unwrap_or(0.0) - s).abs() < 1.0).unwrap_or(true))
    })
}

/// Nhắc đã tới giờ (lấy ra khỏi danh sách): {k, n, t, s, kick, text}; bỏ nhắc quá cũ (đã qua 30 phút).
pub fn due_reminder() -> Option<Value> {
    let now = now_ms();
    let all = reminders();
    let i = all.iter().position(|r| r["at"].as_i64().unwrap_or(0) <= now)?;
    let mut rest = all.clone();
    let mut r = rest.remove(i);
    prefs::set("iptv_reminders", Some(rest));
    let s = r["s"].as_f64().unwrap_or(0.0);
    if now as f64 / 1000.0 > s + 30.0 * 60.0 {
        return None;
    }
    let text = if r["kick"].as_bool().unwrap_or(false) {
        format!("Bóng lăn: {}", r["n"].as_str().unwrap_or(""))
    } else {
        format!("{} lúc {} trên {}", r["t"].as_str().unwrap_or(""), clock(s), r["n"].as_str().unwrap_or(""))
    };
    r["text"] = json!(text);
    Some(r)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_pasted_urls() {
        let u = split_urls(
            "https://a.example/list1\n  http://b.example/x.m3u  \n\n# ghi chú\nshort.example/aaa111\nshort.example/bbb222 short.example/bbb222\n\
             «Danh sách 1»: <https://c.example/y.m3u8>, chữ thường\r\nHTTPS://D.example/Z\n",
        );
        assert_eq!(
            u,
            vec![
                "https://a.example/list1",
                "http://b.example/x.m3u",
                "http://short.example/aaa111",
                "http://short.example/bbb222",
                "https://c.example/y.m3u8",
                "HTTPS://D.example/Z",
            ]
        );
        assert!(split_urls("  \n# chỉ chú thích\nkhông có địa chỉ").is_empty());
        // http / https, tên miền hoa / thường, dấu / cuối: cùng một danh sách; đường dẫn khác hoa / thường: khác danh sách
        assert_eq!(split_urls("http://A.example/x/\nhttps://a.example/x\na.example/X").len(), 2);
        assert_eq!(list_url_key("HTTPS://Short.Gy/AbC/"), "short.gy/AbC");
    }

    fn read(text: &str) -> (Option<String>, Vec<Entry>) {
        let mut r = Reader::default();
        let e: Vec<Entry> = text.lines().filter_map(|l| r.line(l)).collect();
        (r.epg, e)
    }

    #[test]
    fn reads_extinf() {
        let (epg, e) = read(
            "\u{feff}#EXTM3U url-tvg=\"https://a.example/epg.xml,https://b.example/epg.xml.gz\"\n\
             #EXTINF:-1 tvg-id=\"vtv1.vn\" tvg-logo=\"http://l/1.png\" group-title=\"Tin tức, thời sự\",VTV1 HD\n\
             #EXTVLCOPT:http-referrer=https://ref.example/\n#EXTVLCOPT:http-user-agent=Player/1.0\nhttps://s.example/vtv1.m3u8\n\
             #EXTINF:-1,Kênh B\n#EXTGRP:Giải trí\nhttp://s.example/b.m3u8|Referer=https%3A%2F%2Fr.example%2F&User-Agent=UA2\n",
        );
        assert_eq!(epg.as_deref(), Some("https://a.example/epg.xml"));
        assert_eq!(e.len(), 2);
        assert_eq!(e[0].name, "VTV1 HD");
        assert_eq!(e[0].group, "Tin tức, thời sự");
        assert_eq!(e[0].referer.as_deref(), Some("https://ref.example/"));
        assert_eq!(e[0].ua.as_deref(), Some("Player/1.0"));
        assert_eq!(e[1].group, "Giải trí");
        assert_eq!(e[1].url, "http://s.example/b.m3u8");
        assert_eq!(e[1].referer.as_deref(), Some("https://r.example/"));
    }

    #[test]
    fn names_and_kinds() {
        assert_eq!(norm("VTV1 HD"), "vtv1");
        assert_eq!(norm("An Ninh TV HD (1080p) [Geo-blocked]"), "anninhtv");
        assert_eq!(norm("Đồng Tháp FHD"), "dongthap");
        assert_eq!(display_name("|ALB| SUPER SPORT 1 HD"), "SUPER SPORT 1 HD");
        assert_eq!(display_name("Can Tho TV 2 (1080p) [Geo-blocked]"), "Can Tho TV 2");
        assert!(is_placeholder("https://x.example/static/no-signal/low.m3u8"));
        assert_eq!(source_rank("http://a/b.flv?t=1"), 1);
        assert!(is_vod("http://h:80/series/u/p/1.mkv"));
        assert!(!is_vod("http://h:80/u/p/3396"));
        assert!(is_radio(&HashMap::new(), &norm("KÊNH RADIO NƯỚC NGOÀI"), "m3u8"));
        assert_eq!(name_from_file("4k viptv-playlist---2026-11-11T131814-437.m3u"), "4k viptv-playlist");
        assert_eq!(name_from_url("http://short.example/ab"), "short.example");
    }

    #[test]
    fn kickoffs() {
        let now = days_from_civil(2026, 11, 16) as f64 * 86400.0 + 5.0 * 3600.0;
        let n = "20:00 16/11 ⚽ Việt Nam vs Thái Lan (BLV Quang Huy) [hls]";
        let k = kickoff(n, now).unwrap();
        assert_eq!(k.at, days_from_civil(2026, 11, 16) as f64 * 86400.0 + 13.0 * 3600.0);
        assert_eq!(match_name(n, &k), "⚽ Việt Nam vs Thái Lan (BLV Quang Huy)");
        let k2 = kickoff("16/11 02h45 Real - Barca", now).unwrap();
        assert_eq!(k2.at, days_from_civil(2026, 11, 15) as f64 * 86400.0 + (19 * 3600 + 45 * 60) as f64);
        let dec = days_from_civil(2026, 12, 31) as f64 * 86400.0;
        assert_eq!(kickoff("19:30 01/01 A vs B", dec).unwrap().at, days_from_civil(2027, 1, 1) as f64 * 86400.0 + (12 * 3600 + 1800) as f64);
        assert!(kickoff("VTV1 HD", now).is_none());
        assert!(kickoff("120:00 16/11 x", now).is_none());
        assert_eq!(match_state(1000.0, 130, 1000.0 - 3600.0), Match::Later);
        assert_eq!(match_state(1000.0, 130, 1001.0), Match::Live);
    }

    #[test]
    fn builds_and_merges() {
        let m3u = "#EXTM3U\n#EXTINF:-1 group-title=\"Thể thao\",20:00 16/11 ⚽ A vs B (BLV X) [hls]\nhttp://a/x.m3u8\n\
                   #EXTINF:-1 group-title=\"Thể thao\",20:00 16/11 ⚽ A vs B (BLV X) [flv]\n#EXTVLCOPT:http-referrer=https://r/\nhttp://a/x.flv\n\
                   #EXTINF:-1 group-title=\"Thể thao\",20:00 16/11 ⚽ A vs B (BLV Y) [hls]\nhttp://a/y.m3u8\n\
                   #EXTINF:-1 group-title=\"VTV\",VTV1 HD\nhttp://v/1.m3u8\n#EXTINF:-1 group-title=\"VTV\",VTV1 FHD\nhttp://v/1b.m3u8\n";
        let l = build("t", m3u.as_bytes(), days_from_civil(2026, 11, 16) as f64 * 86400.0);
        assert_eq!(l.channels.len(), 3);
        assert!(l.has_matches);
        assert_eq!(l.channels[0].urls, vec!["http://a/x.m3u8", "http://a/x.flv"]);
        assert_eq!(l.channels[0].headers_for("http://a/x.flv").0.as_deref(), Some("https://r/"));
        assert_eq!(l.channels[2].urls.len(), 2);
        assert_eq!(l.groups, vec!["Thể thao", "VTV"]);
    }

    #[test]
    fn home_rows_pick_channels() {
        let base = days_from_civil(2026, 11, 16) as f64 * 86400.0;
        let m3u = "#EXTM3U\n#EXTINF:-1 group-title=\"Thể thao\",20:00 16/11 ⚽ A vs B (BLV X)\nhttp://a/x.m3u8\n\
                   #EXTINF:-1 group-title=\"Thể thao\",22:00 16/11 ⚽ C vs D\nhttp://a/c.m3u8\n\
                   #EXTINF:-1 group-title=\"Thể thao\",23:30 18/11 ⚽ E vs F\nhttp://a/e.m3u8\n\
                   #EXTINF:-1 group-title=\"VTV\",VTV1 HD\nhttp://v/1.m3u8\n#EXTINF:-1 group-title=\"VTV\",VTV3\nhttp://v/3.m3u8\n\
                   #EXTINF:-1 group-title=\"Radio\",VOV1\nhttp://r/vov1.m3u8\n#EXTINF:-1 group-title=\"Radio\",VOV2\nhttp://r/vov2.m3u8\n\
                   #EXTINF:-1 group-title=\"Thiếu nhi\",Kênh Bé\nhttp://k/1.m3u8\n";
        let l = build("L1", m3u.as_bytes(), base);
        // 20:00 giờ Việt Nam = 13:00 UTC; xem lúc 20:10 (trận A–B đang đá, C–D sắp đá 22:00, E–F hai ngày nữa — không hiện)
        let now = base + 13.0 * 3600.0 + 600.0;
        let recent = vec![
            json!({"k": "vov2", "n": "VOV2", "g": "Radio", "l": "L1", "radio": true}),
            json!({"k": "khac", "n": "Kênh danh sách khác", "g": "Phim", "l": "L2"}),
            json!({"k": "vtv1", "n": "VTV1 HD", "g": "VTV", "l": "L1"}),
        ];
        let favs = vec!["vtv3".to_string(), "khongco".to_string()];
        let v = home_rows_of(&l, None, &recent, &favs, false, false, &Map::new(), now, 16);
        let names = |k: &str| v[k].as_array().unwrap().iter().map(|c| c["n"].as_str().unwrap_or("").to_string()).collect::<Vec<_>>();
        assert_eq!(names("recent"), ["VOV2", "Kênh danh sách khác", "VTV1 HD"]);
        assert_eq!(v["recent"][0]["l"], "L1");
        assert_eq!(v["recent"][1]["l"], "L2");
        assert_eq!(names("favs"), ["VTV3"]);
        assert_eq!(v["live"].as_array().unwrap().len(), 2);
        assert_eq!(v["live"][0]["match"], "live");
        assert_eq!(v["live"][1]["match"], "later");
        assert!(v["live"][0]["frac"].as_f64().unwrap() > 0.0);
        assert_eq!(names("radio"), ["VOV2", "VOV1"]);
        // Hồ sơ trẻ em: chỉ kênh thiếu nhi, không trận / radio
        let k = home_rows_of(&l, None, &recent, &favs, true, false, &Map::new(), now, 16);
        assert!(k["recent"].as_array().unwrap().is_empty() && k["favs"].as_array().unwrap().is_empty());
        assert!(k["live"].as_array().unwrap().is_empty() && k["radio"].as_array().unwrap().is_empty());
        let kid = vec![json!({"k": "kenhbe", "n": "Kênh Bé", "l": "L1"})];
        assert_eq!(home_rows_of(&l, None, &kid, &[], true, false, &Map::new(), now, 16)["recent"][0]["n"], "Kênh Bé");
    }

    #[test]
    fn xmltv() {
        let x = r#"<?xml version="1.0"?><tv><!-- a > b --><channel id="vtv1.vn"><display-name>VTV1</display-name></channel>
            <channel id="x2"><display-name lang="vi">VTV2 HD</display-name></channel>
            <programme start="20261116190000 +0700" stop="20261116193000 +0700" channel="vtv1.vn"><title>Thời sự &amp; tin</title></programme>
            <programme start="20261116190000 +0700" stop="20261116200000 +0700" channel="x2"><title lang="vi">Phim</title><desc>…</desc></programme>
            <programme start="20261116190000 +0700" channel="other"><title>Bỏ</title></programme></tv>"#;
        let tids: HashSet<String> = ["vtv1.vn".to_string()].into();
        let keys: HashSet<String> = ["vtv2".to_string()].into();
        let p = parse_xmltv(x.as_bytes(), &tids, &keys, 0.0, 1e12);
        assert_eq!(p.len(), 2);
        assert_eq!(p["vtv1.vn"][0].t, "Thời sự & tin");
        assert_eq!(p["n:vtv2"][0].e - p["n:vtv2"][0].s, 3600.0);
        assert_eq!(xmltv_time("20261116190000 +0700"), Some(days_from_civil(2026, 11, 16) as f64 * 86400.0 + 12.0 * 3600.0));
    }
}

/// Đo tốc độ đọc một danh sách thật: `IPTV_BENCH=<tệp.m3u> cargo test -p conbang-core --release --lib iptv::bench -- --ignored --nocapture`
#[cfg(test)]
mod bench {
    #[test]
    #[ignore]
    fn bench() {
        let Some(p) = std::env::var_os("IPTV_BENCH") else { return };
        let t0 = std::time::Instant::now();
        let f = std::fs::File::open(p).unwrap();
        let l = super::build("b", super::open_maybe_gz(f), super::now_sec());
        let t1 = t0.elapsed();
        let ids = super::filtered(&std::sync::Arc::new(l), &super::Filter { q: "sport".into(), ..Default::default() });
        println!("BENCH {:?} đọc, lọc «sport» {} kênh ({:?})", t1, ids.len(), t0.elapsed() - t1);
    }
}
