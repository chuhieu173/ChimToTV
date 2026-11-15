//! dexter.pw («Stream», Windows 1.17 / Linux 1.3) — bản Android: Dexter.kt, iPad: Dexter.swift (giữ cùng tên hàm để sửa song
//! song). Phim Âu Mỹ (khoảng 6 400 phim lẻ, nhiều phim 4K) và phim bộ; ứng dụng React có API JSON, mã phim là mã TMDB:
//! - /api/site/dexter?v=8: trang chủ (hero + shelves); /api/site/dexter/series: trang phim bộ (cùng dạng).
//! - /api/browse?type=movie&page=N&site=dexter[&genre=<mã TMDB>][&sort=added][&decade=1990]: 40 phim / trang.
//! - /api/search?q=…&type=all&page=1&site=dexter.
//! - /api/movie/<id>, /api/tv/<id>, /api/tv/<id>/season/<n>, /api/tv/<id>/episode/<mùa>/<tập> (?site=dexter).
//! - sources: [{kind:"hls", url:"/api/s/21/…", family:21}] → danh sách HLS chính (4K / 1080p / 720p, fMP4, đoạn đổi đuôi ảnh);
//!   máy chủ 20 của phim bộ tách âm thanh ra luồng riêng → trang hls.html với bản hls.js đầy đủ (Video.hls).
//! - /api/subs/list/movie/<id> | /tv/<id>/<mùa>/<tập>: phụ đề OpenSubtitles + Subsource (phim bộ hay trả {pending:true} một
//!   lúc); tệp: /api/subs/file/<…>/<mã tệp>.vtt (vài tệp 404 «No such subtitle» → trang hls.html thử tệp sau).
//! Địa chỉ trong app theo đường dẫn của trang: phim = /movie/<id>-<slug>, phim bộ = /show/<id>-<slug>, tập phim lẻ =
//! /watch/<id>-<slug>, tập phim bộ = /watch/show/<id>-<slug>/<mùa>/<tập>. Danh sách = địa chỉ API.
use crate::json::{self, Obj};
use crate::models::*;
use crate::site::{distinct_by, json_object};
use crate::util::{form_encoded, Error, Result};
use crate::{api_site, http, site};
use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use regex::Regex;
use std::collections::HashMap;
use std::sync::LazyLock;
use std::time::Duration;

pub const HOST: &str = "dexter.pw";
const SITE: &str = "dexter";
const IMG: &str = "https://image.tmdb.org/t/p/";

/// Ngôn ngữ phụ đề rời cho chọn (người xem Việt): tiếng Việt trước (tối đa 12 tệp), tiếng Anh sau (tối đa 4).
const SUB_LANGS: &[(&str, &str, usize)] = &[("vi", "Tiếng Việt", 12), ("en", "Tiếng Anh", 4)];

/// Thể loại TMDB (phim lẻ + phim bộ) → tên tiếng Việt.
const GENRE_VI: &[(i64, &str)] = &[
    (28, "Hành động"), (12, "Phiêu lưu"), (16, "Hoạt hình"), (35, "Hài"), (80, "Hình sự"), (99, "Tài liệu"), (18, "Chính kịch"),
    (10751, "Gia đình"), (14, "Giả tưởng"), (36, "Lịch sử"), (27, "Kinh dị"), (10402, "Âm nhạc"), (9648, "Bí ẩn"),
    (10749, "Lãng mạn"), (878, "Khoa học viễn tưởng"), (10770, "Phim truyền hình"), (53, "Gay cấn"), (10752, "Chiến tranh"),
    (37, "Miền Tây"), (10759, "Hành động & phiêu lưu"), (10762, "Thiếu nhi"), (10763, "Tin tức"), (10764, "Truyền hình thực tế"),
    (10765, "Viễn tưởng & giả tưởng"), (10766, "Phim dài tập"), (10767, "Talk show"), (10768, "Chiến tranh & chính trị"),
];
const GENRE_NAME: &[(&str, i64)] = &[
    ("Action", 28), ("Adventure", 12), ("Animation", 16), ("Comedy", 35), ("Crime", 80), ("Documentary", 99), ("Drama", 18),
    ("Family", 10751), ("Fantasy", 14), ("History", 36), ("Horror", 27), ("Music", 10402), ("Mystery", 9648),
    ("Romance", 10749), ("Science Fiction", 878), ("TV Movie", 10770), ("Thriller", 53), ("War", 10752), ("Western", 37),
    ("Action & Adventure", 10759), ("Kids", 10762), ("News", 10763), ("Reality", 10764), ("Sci-Fi & Fantasy", 10765),
    ("Soap", 10766), ("Talk", 10767), ("War & Politics", 10768),
];

/// Thể loại cho mục «Thể loại…» (phim lẻ — browse chỉ lọc phim lẻ).
const FILTER_GENRES: &[i64] = &[28, 12, 16, 35, 80, 99, 18, 10751, 14, 36, 27, 10402, 9648, 10749, 878, 53, 10752, 37];

/// Mục «Thập niên…» (thay cho «Quốc gia…» — trang không lọc theo nước).
const DECADES: &[i64] = &[2020, 2010, 2000, 1990, 1980, 1970, 1960, 1950];

/// Tên khối trang chủ của trang (tiếng Anh) → tiếng Việt; khối thể loại đọc theo mã (dexter-genre-<mã>).
const SHELF_VI: &[(&str, &str)] = &[
    ("Recently Added", "Phim mới thêm"), ("Series", "Phim bộ"), ("Top Rated", "Điểm cao"), ("Classics", "Kinh điển"),
    ("Most Liked on Stream", "Được thích nhất"), ("Top 10 Films on Stream", "Top 10 phim lẻ"),
];

/// Ký tự giữ nguyên khi ghép mã tệp phụ đề vào đường dẫn.
const SEG: &AsciiSet = &NON_ALPHANUMERIC.remove(b'-').remove(b'.').remove(b'_').remove(b'~');

static GENRE_SHELF: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"genre-(\d+)$").unwrap());
static REF: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^/(?:watch/)?(show|movie)/(\d+)").unwrap());
static WATCH_MOVIE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^/watch/(\d+)").unwrap());
static WATCH_EP: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^/watch/show/(\d+)[^/]*/(\d+)/(\d+)").unwrap());
static GENERIC_EP: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^episode\s*\d+$").unwrap());

pub fn is_site(url: &str) -> bool {
    site::host_of(url).as_deref() == Some(HOST)
}

fn genre_vi(id: i64) -> Option<&'static str> {
    GENRE_VI.iter().find(|g| g.0 == id).map(|g| g.1)
}

// ---- Trang chủ / danh sách ----

pub async fn home(base_url: &str) -> Result<Home> {
    let o = api_site::origin(base_url);
    let sections = parse_shelves(&get_json(&site_api(&o)).await?, &o);
    if sections.is_empty() {
        return Err(Error::app(format!("Không đọc được trang chủ của {HOST}")));
    }
    Ok(Home { sections, categories: menu_of(base_url), moved_to: None })
}

fn site_api(o: &str) -> String {
    format!("{o}/api/site/{SITE}?v=8")
}

fn series_api(o: &str) -> String {
    format!("{o}/api/site/{SITE}/series")
}

fn browse(o: &str, query: &str) -> String {
    let q = if query.is_empty() { String::new() } else { format!("&{query}") };
    format!("{o}/api/browse?type=movie{q}&page=1&site={SITE}")
}

/// Trang chủ / trang phim bộ: hero thành «Nổi bật», mỗi shelf một khối (shelf bộ sưu tập không có phim thì bỏ).
pub fn parse_shelves(root: &Obj, o: &str) -> Vec<FilmSection> {
    let mut out = Vec::new();
    let hero = films(json::arr(Some(root), "hero"), o);
    if !hero.is_empty() {
        out.push(FilmSection { title: "Nổi bật".into(), films: hero });
    }
    for s in json::objects(json::arr(Some(root), "shelves")) {
        let f = films(json::arr(Some(s), "items"), o);
        if !f.is_empty() {
            out.push(FilmSection { title: shelf_title(s), films: f });
        }
    }
    out
}

fn shelf_title(s: &Obj) -> String {
    let title = json::str(Some(s), "title");
    let id = json::str(Some(s), "id");
    if let Some(vi) = GENRE_SHELF.captures(&id).and_then(|c| c[1].parse::<i64>().ok()).and_then(genre_vi) {
        return vi.to_string();
    }
    SHELF_VI.iter().find(|x| x.0 == title).map(|x| x.1.to_string()).unwrap_or(title)
}

pub fn menu_of(base_url: &str) -> Vec<Category> {
    let o = api_site::origin(base_url);
    vec![
        Category::new("Phim mới & nổi bật", browse(&o, "")),
        Category::new("Phim mới thêm", browse(&o, "sort=added")),
        Category::new("Phim bộ", series_api(&o)),
        Category::new("Hoạt hình", browse(&o, "genre=16")),
        Category::new("Gia đình", browse(&o, "genre=10751")),
        Category::new("Hành động", browse(&o, "genre=28")),
        Category::new("Khoa học viễn tưởng", browse(&o, "genre=878")),
        Category::new("Hài", browse(&o, "genre=35")),
        Category::new("Kinh dị", browse(&o, "genre=27")),
    ]
}

/// (thể loại phim lẻ, thập niên).
pub fn filters(base_url: &str) -> (Vec<Category>, Vec<Category>) {
    let o = api_site::origin(base_url);
    (
        FILTER_GENRES.iter().map(|g| Category::new(genre_vi(*g).unwrap_or(""), browse(&o, &format!("genre={g}")))).collect(),
        DECADES.iter().map(|d| Category::new(format!("Thập niên {d}"), browse(&o, &format!("decade={d}")))).collect(),
    )
}

pub fn newest_url(base_url: &str) -> String {
    browse(&api_site::origin(base_url), "sort=added")
}

pub fn search_url(base_url: &str, query: &str) -> String {
    format!("{}/api/search?q={}&type=all&page=1&site={SITE}", api_site::origin(base_url), form_encoded(query.trim()))
}

pub async fn list(url: &str) -> Result<FilmPage> {
    let root = get_json(url).await?;
    // Trang phim bộ: các khối như trang chủ
    if path_of(url).starts_with("/api/site/") {
        return Ok(FilmPage { films: Vec::new(), next_url: None, sections: parse_shelves(&root, &api_site::origin(url)) });
    }
    Ok(parse_list(&root, url))
}

/// {page, totalPages, results:[…]} (browse / search) → trang sau = page + 1.
pub fn parse_list(root: &Obj, url: &str) -> FilmPage {
    let films = films(json::arr(Some(root), "results"), &api_site::origin(url));
    let page = json::int(Some(root), "page", 1);
    let next = (!films.is_empty() && page < json::int(Some(root), "totalPages", 0)).then(|| api_site::with_page(url, page + 1));
    FilmPage { films, next_url: next, sections: Vec::new() }
}

fn films(a: Option<&Vec<serde_json::Value>>, o: &str) -> Vec<Film> {
    distinct_by(json::objects(a).into_iter().filter_map(|it| film(it, o)), |f| f.url.clone())
}

fn playable(o: &Obj) -> bool {
    !o.contains_key("playable") || json::bool(Some(o), "playable", true)
}

/// Thẻ phim: phim bộ ghi số mùa, phim lẻ ghi năm. Phim trang chưa phát được (playable=false) thì bỏ.
fn film(it: &Obj, o: &str) -> Option<Film> {
    if !playable(it) {
        return None;
    }
    let id = json::int(Some(it), "id", 0);
    let title = json::str(Some(it), "title");
    if id <= 0 || title.is_empty() {
        return None;
    }
    let tv = json::str(Some(it), "type") == "tv";
    let seasons = json::int(Some(it), "seasons", 0);
    let year = json::int(Some(it), "year", 0);
    let badge = if tv {
        Some(if seasons > 0 { format!("Phim bộ · {seasons} mùa") } else { "Phim bộ".into() })
    } else {
        (year > 0).then(|| year.to_string())
    };
    Some(Film::new(film_url(o, tv, id, &title), title.clone(), image(&json::str(Some(it), "poster"), "w342"), badge))
}

pub fn film_url(o: &str, tv: bool, id: i64, title: &str) -> String {
    format!("{o}/{}/{id}-{}", if tv { "show" } else { "movie" }, slug(title))
}

/// "I'm Not Ashamed" → "i-m-not-ashamed" (như đường dẫn của trang; trang chỉ đọc mã số đứng trước).
pub fn slug(title: &str) -> String {
    let mut out = String::new();
    let mut dash = false;
    for c in title.chars().flat_map(|c| c.to_lowercase()) {
        let c = fold(c);
        if c.is_ascii_alphanumeric() {
            out.push(c);
            dash = false;
        } else if !dash && !out.is_empty() {
            out.push('-');
            dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    if out.is_empty() { "phim".into() } else { out }
}

/// Bỏ dấu chữ Latin thường gặp (tên phim Âu Mỹ, tiếng Việt).
fn fold(c: char) -> char {
    const GROUPS: &[(&str, char)] = &[
        ("àáạảãâầấậẩẫăằắặẳẵäåāą", 'a'), ("èéẹẻẽêềếệểễëēęě", 'e'), ("ìíịỉĩîïī", 'i'), ("òóọỏõôồốộổỗơờớợởỡöøō", 'o'),
        ("ùúụủũưừứựửữûüū", 'u'), ("ỳýỵỷỹÿ", 'y'), ("đ", 'd'), ("ñń", 'n'), ("çćč", 'c'), ("šś", 's'), ("žźż", 'z'), ("ł", 'l'),
    ];
    if c.is_ascii() {
        return c;
    }
    GROUPS.iter().find(|g| g.0.contains(c)).map(|g| g.1).unwrap_or(c)
}

// ---- Chi tiết phim ----

fn path_of(url: &str) -> String {
    url::Url::parse(url).map(|u| u.path().to_string()).unwrap_or_default()
}

/// Phim / phim bộ trong địa chỉ của app: (phim bộ?, mã TMDB).
fn reference(url: &str) -> Result<(bool, i64)> {
    let p = path_of(url);
    if let Some(c) = REF.captures(&p) {
        return Ok((&c[1] == "show", c[2].parse().unwrap_or(0)));
    }
    if let Some(c) = WATCH_MOVIE.captures(&p) {
        return Ok((false, c[1].parse().unwrap_or(0)));
    }
    Err(Error::app(format!("Địa chỉ phim lạ: {url}")))
}

pub async fn detail(url: &str) -> Result<FilmDetail> {
    let o = api_site::origin(url);
    let (tv, id) = reference(url)?;
    if !tv {
        return parse_movie(&get_json(&format!("{o}/api/movie/{id}?site={SITE}")).await?, &o);
    }
    let show = get_json(&format!("{o}/api/tv/{id}?site={SITE}")).await?;
    let mut seasons: Vec<i64> = json::objects(json::arr(Some(&show), "seasonList"))
        .into_iter()
        .filter(|s| playable(s))
        .map(|s| json::int(Some(s), "number", 0))
        .collect();
    seasons.sort_by_key(|n| (*n == 0, *n)); // mùa đặc biệt (0) xuống cuối
    // Các mùa tải song song — phim bộ dài có hàng chục mùa
    let bodies = futures::future::join_all(seasons.iter().map(|n| {
        let u = format!("{o}/api/tv/{id}/season/{n}?site={SITE}");
        async move { get_json(&u).await.ok() }
    }))
    .await;
    let loaded: Vec<(i64, Obj)> = seasons.into_iter().zip(bodies).filter_map(|(n, b)| b.map(|b| (n, b))).collect();
    parse_show(&show, &loaded, &o)
}

pub fn parse_movie(m: &Obj, o: &str) -> Result<FilmDetail> {
    let id = json::int(Some(m), "id", 0);
    if id <= 0 {
        return Err(Error::app("Không đọc được thông tin phim"));
    }
    let title = json::str(Some(m), "title");
    let year = json::int(Some(m), "year", 0);
    let runtime = json::int(Some(m), "runtime", 0);
    let info = join_info(vec![
        if year > 0 { year.to_string() } else { String::new() },
        if runtime > 0 { format!("{runtime} phút") } else { String::new() },
        json::str(Some(m), "certification"),
        genres(m),
        rating(m),
    ]);
    let url = film_url(o, false, id, &title);
    let groups = if playable(m) {
        vec![EpisodeGroup {
            name: "Phim".into(),
            episodes: vec![Episode::new("Xem phim", format!("{o}/watch/{id}-{}", slug(&title)))],
        }]
    } else {
        Vec::new()
    };
    Ok(FilmDetail {
        title: if title.is_empty() { url.clone() } else { title },
        url,
        other_title: ne(&json::str(Some(m), "tagline")),
        poster: image(&json::str(Some(m), "poster"), "w500"),
        description: ne(&json::str(Some(m), "overview")),
        info,
        groups,
        seasons: false,
    })
}

/// seasons: (số mùa, JSON của mùa) — mỗi mùa một nhóm tập («Mùa 1»…); tập trang chưa phát được thì bỏ.
pub fn parse_show(show: &Obj, seasons: &[(i64, Obj)], o: &str) -> Result<FilmDetail> {
    let id = json::int(Some(show), "id", 0);
    if id <= 0 {
        return Err(Error::app("Không đọc được thông tin phim"));
    }
    let title = json::str(Some(show), "title");
    let s = slug(&title);
    let groups: Vec<EpisodeGroup> = seasons
        .iter()
        .filter_map(|(n, body)| {
            let eps: Vec<Episode> = json::objects(json::arr(Some(body), "episodes"))
                .into_iter()
                .filter(|e| playable(e))
                .filter_map(|e| {
                    let ep = json::int(Some(e), "episode", 0);
                    if ep <= 0 {
                        return None;
                    }
                    let name = json::str(Some(e), "title");
                    let suffix = if name.is_empty() || GENERIC_EP.is_match(&name) { String::new() } else { format!(" · {name}") };
                    Some(Episode::new(format!("Tập {ep}{suffix}"), format!("{o}/watch/show/{id}-{s}/{n}/{ep}")))
                })
                .collect();
            (!eps.is_empty()).then(|| EpisodeGroup {
                name: if *n == 0 { FilmDetail::SPECIALS.into() } else { format!("Mùa {n}") },
                episodes: eps,
            })
        })
        .collect();
    let mut years: Vec<String> = Vec::new();
    for y in [json::int(Some(show), "year", 0), json::int(Some(show), "endYear", 0)] {
        if y > 0 && !years.contains(&y.to_string()) {
            years.push(y.to_string());
        }
    }
    let n = json::int(Some(show), "seasons", 0);
    let count = json::int(Some(show), "episodeCount", 0);
    let status = match json::str(Some(show), "status").as_str() {
        "Ended" => "Đã kết thúc",
        "Returning Series" => "Đang chiếu",
        _ => "",
    };
    let info = join_info(vec![
        years.join("–"),
        if n > 0 { format!("{n} mùa") } else { String::new() },
        if count > 0 { format!("{count} tập") } else { String::new() },
        json::str(Some(show), "certification"),
        status.to_string(),
        genres(show),
        rating(show),
    ]);
    Ok(FilmDetail {
        url: film_url(o, true, id, &title),
        title: if title.is_empty() { "Phim bộ".into() } else { title },
        other_title: ne(&json::str(Some(show), "tagline")),
        poster: image(&json::str(Some(show), "poster"), "w500"),
        description: ne(&json::str(Some(show), "overview")),
        info,
        groups,
        seasons: true,
    })
}

fn join_info(parts: Vec<String>) -> Option<String> {
    let s = parts.into_iter().filter(|p| !p.is_empty()).collect::<Vec<_>>().join("  •  ");
    ne(&s)
}

fn genres(o: &Obj) -> String {
    json::arr(Some(o), "genres")
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str())
                .filter(|g| !g.is_empty())
                .map(|g| GENRE_NAME.iter().find(|x| x.0 == g).and_then(|x| genre_vi(x.1)).unwrap_or(g).to_string())
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_default()
}

fn rating(o: &Obj) -> String {
    match json::num(Some(o), "rating") {
        Some(r) if r > 0.0 && json::int(Some(o), "votes", 0) >= 20 => format!("TMDB {r:.1}"),
        _ => String::new(),
    }
}

// ---- Tập phim ----

/// Server = mỗi nguồn HLS của trang (phim lẻ: «Server 21»; phim bộ: thêm «Server 20»). Kèm danh sách phụ đề tải song song
/// (tiếng Việt trước); phim bộ hay trả «đang tìm» (pending) → trình phát hỏi lại sau (Video.subs_later).
pub async fn source(ep_url: &str) -> Result<EpisodeSource> {
    let o = api_site::origin(ep_url);
    let p = path_of(ep_url);
    let (key, api) = match WATCH_EP.captures(&p) {
        Some(c) => (format!("tv/{}/{}/{}", &c[1], &c[2], &c[3]), format!("{o}/api/tv/{}/episode/{}/{}?site={SITE}", &c[1], &c[2], &c[3])),
        None => {
            let id = reference(ep_url)?.1;
            (format!("movie/{id}"), format!("{o}/api/movie/{id}?site={SITE}"))
        }
    };
    let list_url = format!("{o}/api/subs/list/{key}");
    let file_base = format!("{o}/api/subs/file/{key}/");
    let subs_fut = async { tokio::time::timeout(Duration::from_secs(8), get_json(&list_url)).await.ok().and_then(|r| r.ok()) };
    let (subs_root, body) = tokio::join!(subs_fut, get_json(&api));
    let (subs, pending) = subs_root.map(|r| subtitles(&r, &file_base)).unwrap_or((Vec::new(), true));
    parse_source(&body?, ep_url, subs, pending.then_some(list_url))
}

/// sources của phim / tập → server + link (HLS, kèm phụ đề). Nguồn «sealed» (mã hoá riêng của trang) bỏ qua.
pub fn parse_source(root: &Obj, ep_url: &str, subs: Vec<SubTrack>, subs_later: Option<String>) -> Result<EpisodeSource> {
    let o = api_site::origin(ep_url);
    let mut links: HashMap<String, Video> = HashMap::new();
    let mut servers: Vec<Server> = Vec::new();
    for s in json::objects(json::arr(Some(root), "sources")) {
        if json::str(Some(s), "kind") != "hls" || json::bool(Some(s), "sealed", false) {
            continue;
        }
        let Some(url) = abs(&o, &json::str(Some(s), "url")) else { continue };
        let family = json::int(Some(s), "family", 0);
        let id = json::str(Some(s), "id");
        let kind = if family > 0 { format!("s{family}") } else if !id.is_empty() { id } else { format!("s{}", servers.len() + 1) };
        if links.contains_key(&kind) {
            continue;
        }
        // Phụ đề riêng của nguồn (đã khớp thời gian với video) đứng trước phụ đề tìm theo tên phim
        let own = own_subtitles(json::arr(Some(s), "subtitles"), &o);
        let label = json::str(Some(s), "label");
        links.insert(
            kind.clone(),
            Video { url, hls: true, subs: merge_subs(own, &subs), subs_later: subs_later.clone(), ..Default::default() },
        );
        servers.push(Server::new(if label.is_empty() { format!("Server {}", servers.len() + 1) } else { label }, kind));
    }
    if links.is_empty() {
        return Err(Error::app(format!("Phim này chưa có video trên {HOST}")));
    }
    Ok(EpisodeSource { ep_url: ep_url.to_string(), servers, links, next: true, ..Default::default() })
}

/// Hỏi lại danh sách phụ đề còn «đang tìm»: (phụ đề, còn đang tìm?).
pub async fn subtitles_from(list_url: &str) -> Result<(Vec<SubTrack>, bool)> {
    let key = list_url.split("/api/subs/list/").nth(1).unwrap_or("");
    let base = format!("{}/api/subs/file/{key}/", api_site::origin(list_url));
    Ok(subtitles(&get_json(list_url).await?, &base))
}

/// {files:[{id, lang, label, source, release, url?}], pending?} → tiếng Việt (tối đa 12) rồi tiếng Anh (tối đa 4), giữ thứ tự
/// của trang (xếp theo độ phổ biến). `file_base`: …/api/subs/file/movie/<id>/
pub fn subtitles(root: &Obj, file_base: &str) -> (Vec<SubTrack>, bool) {
    let files = json::objects(json::arr(Some(root), "files"));
    let o = api_site::origin(file_base);
    let mut out = Vec::new();
    for (lang, name, max) in SUB_LANGS {
        let mine: Vec<&Obj> = files
            .iter()
            .copied()
            .filter(|f| {
                let l = json::str(Some(*f), "lang").to_lowercase();
                l == *lang || l.starts_with(&format!("{lang}-"))
            })
            .take(*max)
            .collect();
        for (i, f) in mine.iter().enumerate() {
            let url = abs(&o, &json::str(Some(*f), "url"))
                .unwrap_or_else(|| format!("{file_base}{}.vtt", utf8_percent_encode(&json::str(Some(*f), "id"), SEG)));
            let label = if mine.len() > 1 { format!("{name} {}", i + 1) } else { name.to_string() };
            out.push(SubTrack { label, url, lang: lang.to_string() });
        }
    }
    let pending = files.is_empty() && json::bool(Some(root), "pending", false);
    (out, pending)
}

fn own_subtitles(a: Option<&Vec<serde_json::Value>>, o: &str) -> Vec<SubTrack> {
    json::objects(a)
        .into_iter()
        .filter_map(|s| {
            let lang = json::str(Some(s), "lang").to_lowercase();
            let lang = lang.split('-').next().unwrap_or("").to_string();
            let name = SUB_LANGS.iter().find(|l| l.0 == lang)?.1;
            let url = abs(o, &json::str(Some(s), "url"))?;
            Some(SubTrack { label: format!("{name} (khớp video)"), url, lang })
        })
        .collect()
}

/// Phụ đề riêng của nguồn trước, mỗi ngôn ngữ vẫn theo thứ tự tiếng Việt → tiếng Anh.
fn merge_subs(own: Vec<SubTrack>, found: &[SubTrack]) -> Vec<SubTrack> {
    if own.is_empty() {
        return found.to_vec();
    }
    SUB_LANGS
        .iter()
        .flat_map(|l| own.iter().filter(|s| s.lang == l.0).chain(found.iter().filter(|s| s.lang == l.0)).cloned().collect::<Vec<_>>())
        .collect()
}

// ---- Tiện ích ----

async fn get_json(url: &str) -> Result<Obj> {
    let r = http::get(url, &[("Accept", "application/json")]).await?;
    let o = json_object(&r.data).ok_or_else(|| Error::app(format!("{HOST} trả dữ liệu lạ")))?;
    if o.len() == 1 {
        if let Some(e) = o.get("error").and_then(|v| v.as_str()) {
            return Err(Error::app(e.to_string()));
        }
    }
    Ok(o)
}

fn image(path: &str, size: &str) -> Option<String> {
    if path.is_empty() {
        None
    } else if path.starts_with("http") {
        Some(path.to_string())
    } else {
        Some(format!("{IMG}{size}{}{path}", if path.starts_with('/') { "" } else { "/" }))
    }
}

fn abs(o: &str, r: &str) -> Option<String> {
    if r.is_empty() {
        None
    } else if r.starts_with("http") {
        Some(r.to_string())
    } else if r.starts_with('/') {
        Some(format!("{o}{r}"))
    } else {
        None
    }
}

fn ne(s: &str) -> Option<String> {
    let t = s.trim();
    (!t.is_empty()).then(|| t.to_string())
}

#[cfg(test)]
mod tests {
    //! dexter.pw (11/2026): mẫu rút gọn từ phản hồi thật của API — cùng ca với DexterTest.kt / DexterTests.swift.
    use super::*;

    const O: &str = "https://dexter.pw";

    fn obj(s: &str) -> Obj {
        json::parse_object(s.as_bytes()).unwrap()
    }

    #[test]
    fn parses_home_shelves() {
        let root = obj(r#"{"hero":[{"type":"tv","id":1405,"title":"Dexter","year":2006,"poster":"/i8OR.jpg","seasons":8,"playable":true},
            {"type":"movie","id":354912,"title":"Coco","year":2017,"poster":"/6Ryi.jpg","playable":true}],
          "shelves":[{"id":"dexter-new","title":"Recently Added","items":[
              {"type":"movie","id":409502,"title":"I'm Not Ashamed","year":2016,"poster":"/a.jpg","playable":true},
              {"type":"movie","id":7,"title":"Chưa có video","year":2020,"playable":false}]},
            {"id":"dexter-film-series","title":"Film Series","items":[]},
            {"id":"dexter-genre-878","title":"Science Fiction","items":[{"type":"movie","id":687163,"title":"Project Hail Mary","year":2026}]},
            {"id":"dexter-other","title":"Something New","items":[{"type":"movie","id":5,"title":"X","poster":null}]}]}"#);
        let s = parse_shelves(&root, O);
        assert_eq!(s.iter().map(|x| x.title.as_str()).collect::<Vec<_>>(), ["Nổi bật", "Phim mới thêm", "Khoa học viễn tưởng", "Something New"]);
        assert_eq!(s[0].films.iter().map(|f| f.url.as_str()).collect::<Vec<_>>(), [format!("{O}/show/1405-dexter"), format!("{O}/movie/354912-coco")]);
        assert_eq!(s[0].films[0].badge.as_deref(), Some("Phim bộ · 8 mùa"));
        assert_eq!(s[0].films[1].badge.as_deref(), Some("2017"));
        assert_eq!(s[0].films[1].poster.as_deref(), Some("https://image.tmdb.org/t/p/w342/6Ryi.jpg"));
        assert_eq!(s[1].films.iter().map(|f| f.url.clone()).collect::<Vec<_>>(), [format!("{O}/movie/409502-i-m-not-ashamed")]);
        assert_eq!(s[3].films[0].poster, None);
    }

    #[test]
    fn parses_browse_pages_and_filters() {
        let url = format!("{O}/api/browse?type=movie&genre=16&page=1&site=dexter");
        let p = parse_list(&obj(r#"{"page":1,"totalPages":161,"results":[{"type":"movie","id":687163,"title":"Project Hail Mary"}]}"#), &url);
        assert_eq!(p.films[0].url, format!("{O}/movie/687163-project-hail-mary"));
        assert_eq!(p.next_url.as_deref(), Some(format!("{O}/api/browse?type=movie&genre=16&page=2&site=dexter").as_str()));
        assert_eq!(parse_list(&obj(r#"{"page":3,"totalPages":3,"results":[{"type":"movie","id":1,"title":"A"}]}"#), &url).next_url, None);
        assert_eq!(search_url(O, " frozen ii "), format!("{O}/api/search?q=frozen+ii&type=all&page=1&site=dexter"));
        let (g, d) = filters(O);
        assert!(g.iter().any(|c| c.title == "Hoạt hình" && c.url == format!("{O}/api/browse?type=movie&genre=16&page=1&site=dexter")));
        assert_eq!(d.iter().find(|c| c.title == "Thập niên 1990").map(|c| c.url.clone()), Some(format!("{O}/api/browse?type=movie&decade=1990&page=1&site=dexter")));
    }

    #[test]
    fn parses_movie_detail() {
        let d = parse_movie(&obj(r#"{"type":"movie","id":354912,"title":"Coco","year":2017,"overview":"Miguel…","poster":"/6Ryi.jpg",
            "genres":["Family","Animation","Music"],"rating":8.2,"votes":21873,"runtime":105,"certification":"PG","playable":true}"#), O)
        .unwrap();
        assert_eq!(d.url, format!("{O}/movie/354912-coco"));
        assert_eq!(d.info.as_deref(), Some("2017  •  105 phút  •  PG  •  Gia đình, Hoạt hình, Âm nhạc  •  TMDB 8.2"));
        assert_eq!(d.groups[0].episodes[0].url, format!("{O}/watch/354912-coco"));
        assert!(!d.seasons);
    }

    #[test]
    fn parses_show_seasons() {
        let show = obj(r#"{"type":"tv","id":1405,"title":"Dexter","year":2006,"endYear":2013,"seasons":8,"episodeCount":96,
            "status":"Ended","genres":["Crime","Drama"],"rating":8.2,"votes":6028}"#);
        let s1 = obj(r#"{"episodes":[{"episode":1,"title":"Dexter","playable":true},{"episode":2,"title":"Episode 2"},
            {"episode":3,"title":"Popping Cherry","playable":false}]}"#);
        let s0 = obj(r#"{"episodes":[{"episode":1,"title":"Early Cuts"}]}"#);
        let d = parse_show(&show, &[(1, s1), (0, s0)], O).unwrap();
        assert_eq!(d.groups.iter().map(|g| g.name.as_str()).collect::<Vec<_>>(), ["Mùa 1", "Tập đặc biệt"]);
        assert_eq!(d.groups[0].episodes.iter().map(|e| e.title.as_str()).collect::<Vec<_>>(), ["Tập 1 · Dexter", "Tập 2"]);
        assert_eq!(d.groups[0].episodes[1].url, format!("{O}/watch/show/1405-dexter/1/2"));
        assert_eq!(d.info.as_deref(), Some("2006–2013  •  8 mùa  •  96 tập  •  Đã kết thúc  •  Hình sự, Chính kịch  •  TMDB 8.2"));
        assert!(d.seasons);
        assert_eq!(d.episode_count(), 3);
        assert_eq!(d.latest_episode().map(|e| e.url.clone()), Some(format!("{O}/watch/show/1405-dexter/1/2")));
    }

    #[test]
    fn picks_vietnamese_then_english_subtitles() {
        let root = obj(r#"{"files":[{"id":"os-1","lang":"en"},{"id":"os-2","lang":"vi"},{"id":"ss-3","lang":"vi"},{"id":"os-4","lang":"ar"},
            {"id":"x 5","lang":"en","url":"/api/s/20/subs/5.vtt"}]}"#);
        let (subs, pending) = subtitles(&root, &format!("{O}/api/subs/file/movie/354912/"));
        assert!(!pending);
        assert_eq!(subs.iter().map(|s| s.label.as_str()).collect::<Vec<_>>(), ["Tiếng Việt 1", "Tiếng Việt 2", "Tiếng Anh 1", "Tiếng Anh 2"]);
        assert_eq!(subs[0].url, format!("{O}/api/subs/file/movie/354912/os-2.vtt"));
        assert_eq!(subs[3].url, format!("{O}/api/s/20/subs/5.vtt"));
        let (none, later) = subtitles(&obj(r#"{"files":[],"pending":true}"#), &format!("{O}/api/subs/file/tv/1405/1/1/"));
        assert!(none.is_empty() && later);
    }

    #[test]
    fn parses_sources_as_hls_servers() {
        let root = obj(r#"{"sources":[{"id":"s20-tv","kind":"hls","url":"/api/s/20/tv/1405/1/1","label":"Server 20","family":20},
            {"id":"s21-tv","kind":"hls","url":"/api/s/21/tv/1405/1/1?v=3","label":"Server 21","family":21},
            {"id":"x","kind":"hls","url":"/api/s/9/tv/1405/1/1","label":"Server 9","family":9,"sealed":true},
            {"id":"e","kind":"embed","url":"https://example.com/embed/1","label":"Embed"}]}"#);
        let subs = vec![SubTrack { label: "Tiếng Việt".into(), url: format!("{O}/api/subs/file/tv/1405/1/1/os-2.vtt"), lang: "vi".into() }];
        let src = parse_source(&root, &format!("{O}/watch/show/1405-dexter/1/1"), subs.clone(), Some(format!("{O}/api/subs/list/tv/1405/1/1"))).unwrap();
        assert_eq!(src.servers.iter().map(|s| s.kind.as_str()).collect::<Vec<_>>(), ["s20", "s21"]);
        let v = &src.links["s21"];
        assert_eq!(v.url, format!("{O}/api/s/21/tv/1405/1/1?v=3"));
        assert!(v.hls);
        assert_eq!(v.subs, subs);
        assert_eq!(v.subs_later.as_deref(), Some(format!("{O}/api/subs/list/tv/1405/1/1").as_str()));
        assert!(src.next);
    }

    #[test]
    fn makes_site_like_slugs() {
        assert_eq!(slug("Spider-Man: Brand New Day"), "spider-man-brand-new-day");
        assert_eq!(slug("I'm Not Ashamed"), "i-m-not-ashamed");
        assert_eq!(slug("Amélie"), "amelie");
        assert_eq!(slug("!!!"), "phim");
        assert_eq!(site::display_name(HOST), "Phim Âu Mỹ 4K (dexter.pw)");
    }

    #[test]
    fn futures_are_send() {
        fn send<T: Send>(_: T) {}
        send(home(""));
        send(list(""));
        send(detail(""));
        send(source(""));
        send(subtitles_from(""));
    }
}
