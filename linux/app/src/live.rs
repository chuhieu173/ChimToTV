//! Trình phát truyền hình / radio (IPTV) bản Linux — libmpv (native.rs): HLS, HTTP-FLV, TS liền, đài MP3 / AAC kèm tên bài ICY,
//! Referer / User-Agent riêng của nguồn. Cùng cách chạy với bản Windows (Player/LiveView.cs) và tivi (LiveActivity.kt): nguồn lỗi
//! tự sang nguồn sau; hỏng hết nguồn thì tải lại danh sách (cũ quá 10 phút) tìm link mới một lần; trận sắp / đang đá mà chưa có
//! hình thì chờ, tải lại danh sách, thử lại mỗi 20 giây; link giả «no-signal» / hình chờ ngắn không phát; đài radio hiện thẻ đài.
//! Phím: ▲ ▼ / PgUp PgDn đổi kênh, Enter hiện nút, ◀ / M bảng kênh (phim: ◀ ▶ tua), số 0–9 gõ số kênh, Space tạm dừng, G lịch,
//! Esc đóng bảng / nút rồi mới thoát.

use crate::app::app;
use crate::keynav::{self, Dir};
use crate::native::Native;
use crate::ui;
use cbtv::iptv::{self, Filter};
use gtk::prelude::*;
use serde_json::{json, Value};
use std::cell::RefCell;
use std::rc::Rc;

fn s(v: &Value, k: &str) -> String {
    v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string()
}
fn d(v: &Value, k: &str) -> f64 {
    v.get(k).and_then(|x| x.as_f64()).unwrap_or(0.0)
}
fn b(v: &Value, k: &str) -> bool {
    v.get(k).and_then(|x| x.as_bool()).unwrap_or(false)
}
fn opt(v: &Value, k: &str) -> Option<String> {
    Some(s(v, k)).filter(|x| !x.is_empty())
}
fn now_ms() -> i64 {
    cbtv::util::now_ms()
}

#[derive(Default)]
struct St {
    open: bool,
    filter: Filter,
    index: usize,
    total: usize,
    ch: Value,
    source: usize,
    token: u64,
    started: bool,
    started_at: i64,
    opened_at: i64,
    reopens: u32,
    list_checked: bool,
    radio: bool,
    icy: Option<String>,
    radio_desc: Option<String>,
    paused_at: i64,
    delay: f64,
    limit_warned: bool,
    ticks: u64,
    digits: String,
    waiting_retry: bool,
    checking: bool,
    error_shown: bool,
}

pub struct Live {
    pub root: gtk::Overlay,
    stage: gtk::Box,
    native: RefCell<Option<Rc<Native>>>,
    st: RefCell<St>,
    top: gtk::Box,
    num: gtk::Label,
    title: gtk::Label,
    badge: gtk::Label,
    clock: gtk::Label,
    notice: gtk::Label,
    bottom: gtk::Box,
    prog: gtk::Label,
    next: gtk::Label,
    time: gtk::Label,
    progress: gtk::ProgressBar,
    btn_play: gtk::Button,
    btn_live: gtk::Button,
    btn_source: gtk::Button,
    btn_fav: gtk::Button,
    btn_guide: gtk::Button,
    panel: gtk::Box,
    panel_title: gtk::Label,
    panel_list: gtk::Box,
    status: gtk::Box,
    spinner: gtk::Spinner,
    status_text: gtk::Label,
    status_buttons: gtk::Box,
    btn_retry: gtk::Button,
    radio_card: gtk::Box,
    radio_logo: gtk::Image,
    radio_icon: gtk::Label,
    radio_name: gtk::Label,
    radio_song: gtk::Label,
    radio_info: gtk::Label,
    hide_timer: RefCell<Option<glib::SourceId>>,
    digits_timer: RefCell<Option<glib::SourceId>>,
    notice_timer: RefCell<Option<glib::SourceId>>,
}

thread_local! {
    static ME: RefCell<Option<Rc<Live>>> = const { RefCell::new(None) };
}

fn me() -> Option<Rc<Live>> {
    ME.with(|m| m.borrow().clone())
}

/// Trình phát truyền hình (một cái cho cả app; tạo lần đầu mở kênh).
pub fn get() -> Rc<Live> {
    if let Some(l) = me() {
        return l;
    }
    let l = Live::new();
    ME.with(|m| *m.borrow_mut() = Some(l.clone()));
    l
}

/// Trình phát truyền hình đang mở.
pub fn current() -> Option<Rc<Live>> {
    me().filter(|l| l.st.borrow().open)
}

fn btn(text: &str, f: impl Fn(&Rc<Live>) + 'static) -> gtk::Button {
    ui::pill(text, move || {
        if let Some(l) = me() {
            f(&l);
        }
    })
}

impl Live {
    fn new() -> Rc<Live> {
        let root = gtk::Overlay::new();
        root.style_context().add_class("player");
        let stage = gtk::Box::new(gtk::Orientation::Vertical, 0);
        stage.set_hexpand(true);
        stage.set_vexpand(true);
        root.add(&stage);

        // Thẻ đài radio
        let radio_card = ui::vbox(6.0);
        radio_card.set_halign(gtk::Align::Center);
        radio_card.set_valign(gtk::Align::Center);
        let logo_box = gtk::Overlay::new();
        logo_box.set_size_request(crate::css::px(170.0), crate::css::px(170.0));
        let radio_icon = ui::label("📻", &["big"], false);
        radio_icon.set_halign(gtk::Align::Center);
        let radio_logo = gtk::Image::new();
        logo_box.add(&radio_icon);
        logo_box.add_overlay(&radio_logo);
        radio_card.pack_start(&logo_box, false, false, 0);
        let radio_name = ui::label("", &["h1"], false);
        let radio_song = ui::label("", &["h2"], true);
        let radio_info = ui::dim("");
        for l in [&radio_name, &radio_song, &radio_info] {
            l.set_halign(gtk::Align::Center);
            l.set_justify(gtk::Justification::Center);
            radio_card.pack_start(l, false, false, 0);
        }
        root.add_overlay(&radio_card);

        // Thanh trên
        let top = ui::hbox(12.0);
        top.style_context().add_class("topbar");
        top.set_valign(gtk::Align::Start);
        let num = ui::dim("");
        let title = ui::label("", &["osd-title"], false);
        title.set_hexpand(true);
        let notice = ui::label("", &["osd-state"], false);
        let badge = ui::label("", &["osd-time"], false);
        let clock = ui::dim("");
        top.pack_start(&num, false, false, 0);
        top.pack_start(&title, true, true, 0);
        top.pack_start(&notice, false, false, 0);
        top.pack_start(&badge, false, false, 0);
        top.pack_start(&clock, false, false, 0);
        root.add_overlay(&top);

        // Thanh dưới
        let bottom = ui::vbox(6.0);
        bottom.style_context().add_class("osd");
        bottom.set_valign(gtk::Align::End);
        let prog_row = ui::hbox(12.0);
        let prog = ui::label("", &["osd-time"], false);
        prog.set_hexpand(true);
        let next = ui::dim("");
        prog_row.pack_start(&prog, true, true, 0);
        prog_row.pack_start(&next, false, false, 0);
        let time = ui::dim("");
        let progress = gtk::ProgressBar::new();
        let btn_play = btn("Tạm dừng", |l| l.toggle_play());
        let btn_live = btn("Về trực tiếp", |l| l.go_live());
        let btn_source = btn("Nguồn 1/1", |l| l.next_source());
        let btn_fav = btn("☆", |l| l.toggle_favorite());
        let btn_guide = btn("Lịch", |l| l.open_guide());
        let buttons: Vec<gtk::Widget> = vec![
            btn("☰ Kênh", |l| l.toggle_panel()).upcast(),
            btn("« Kênh trước", |l| l.step(-1)).upcast(),
            btn_play.clone().upcast(),
            btn("Kênh sau »", |l| l.step(1)).upcast(),
            btn_live.clone().upcast(),
            btn_source.clone().upcast(),
            btn_guide.clone().upcast(),
            btn_fav.clone().upcast(),
            btn("✕ Đóng", |l| l.close()).upcast(),
        ];
        bottom.pack_start(&prog_row, false, false, 0);
        bottom.pack_start(&time, false, false, 0);
        bottom.pack_start(&progress, false, false, 0);
        bottom.pack_start(&ui::row(&buttons), false, false, 0);
        root.add_overlay(&bottom);

        // Đang mở / lỗi
        let status = ui::vbox(14.0);
        status.style_context().add_class("box-dark");
        status.set_halign(gtk::Align::Center);
        status.set_valign(gtk::Align::Center);
        let spinner = gtk::Spinner::new();
        spinner.set_size_request(crate::css::px(44.0), crate::css::px(44.0));
        let status_text = ui::label("", &["h2"], true);
        status_text.set_justify(gtk::Justification::Center);
        status_text.set_halign(gtk::Align::Center);
        status_text.set_max_width_chars(60);
        let btn_retry = btn("Thử lại", |l| l.retry());
        let status_buttons = ui::hbox(10.0);
        status_buttons.set_halign(gtk::Align::Center);
        status_buttons.pack_start(&btn_retry, false, false, 0);
        status_buttons.pack_start(&btn("Kênh sau »", |l| l.step(1)), false, false, 0);
        status_buttons.pack_start(&btn("Quay lại", |l| l.close()), false, false, 0);
        status.pack_start(&spinner, false, false, 0);
        status.pack_start(&status_text, false, false, 0);
        status.pack_start(&status_buttons, false, false, 0);
        root.add_overlay(&status);

        // Bảng kênh
        let panel = ui::vbox(6.0);
        panel.style_context().add_class("panel");
        panel.set_halign(gtk::Align::End);
        panel.set_size_request(crate::css::px(380.0), -1);
        let panel_title = ui::label("", &["panel-title"], false);
        ui::margins(&panel_title, 14.0, 16.0, 6.0, 16.0);
        let (panel_scroll, panel_list) = ui::scroller();
        panel_scroll.set_vexpand(true);
        panel.pack_start(&panel_title, false, false, 0);
        panel.pack_start(&panel_scroll, true, true, 0);
        root.add_overlay(&panel);

        let l = Rc::new(Live {
            root, stage, native: RefCell::new(None), st: RefCell::new(St::default()), top, num, title, badge, clock, notice, bottom, prog,
            next, time, progress, btn_play, btn_live, btn_source, btn_fav, btn_guide, panel, panel_title, panel_list, status, spinner,
            status_text, status_buttons, btn_retry, radio_card, radio_logo, radio_icon, radio_name, radio_song, radio_info,
            hide_timer: RefCell::new(None), digits_timer: RefCell::new(None), notice_timer: RefCell::new(None),
        });
        l
    }

    pub fn widget(&self) -> gtk::Widget {
        self.root.clone().upcast()
    }

    // ---- Mở / đóng ----

    pub fn open(self: &Rc<Self>, filter: Filter, index: usize) {
        {
            let mut st = self.st.borrow_mut();
            *st = St { open: true, filter, index, ..Default::default() };
        }
        if self.native.borrow().is_none() {
            if let Some(n) = Native::new(crate::player::has_gpu()) {
                n.widget.set_can_focus(false);
                n.widget.set_hexpand(true);
                n.widget.set_vexpand(true);
                self.stage.pack_start(&n.widget, true, true, 0);
                *self.native.borrow_mut() = Some(n);
            }
        }
        self.root.show_all();
        self.panel.hide();
        self.radio_card.hide();
        self.set_controls(true);
        let me = self.clone();
        glib::timeout_add_local(std::time::Duration::from_secs(1), move || {
            if !me.st.borrow().open {
                return glib::ControlFlow::Break;
            }
            me.tick();
            glib::ControlFlow::Continue
        });
        if self.native.borrow().is_none() {
            self.show_error("Máy thiếu thư viện libmpv — không phát được truyền hình (cài gói libmpv).", false, "Thử lại");
            return;
        }
        self.play_at(index);
    }

    pub fn close(self: &Rc<Self>) {
        {
            let mut st = self.st.borrow_mut();
            if !st.open {
                return;
            }
            st.open = false;
            st.token += 1;
        }
        crate::limits::flush();
        if let Some(n) = self.native.borrow_mut().take() {
            n.stop();
            self.stage.remove(&n.widget);
        }
        app().live_closed();
    }

    fn native(&self) -> Option<Rc<Native>> {
        self.native.borrow().clone()
    }

    fn urls(&self) -> Vec<Value> {
        self.st.borrow().ch.get("urls").and_then(|u| u.as_array()).cloned().unwrap_or_default()
    }

    fn play_at(self: &Rc<Self>, index: usize) {
        let (t, filter) = {
            let mut st = self.st.borrow_mut();
            st.token += 1;
            st.started = false;
            (st.token, st.filter.clone())
        };
        if let Some(n) = self.native() {
            n.stop();
        }
        self.show_loading("Đang mở kênh…");
        let me = self.clone();
        ui::spawn(async move { iptv::at(&filter, index).await }, move |ch| {
            if me.st.borrow().token != t || !me.st.borrow().open {
                return;
            }
            if ch.is_null() {
                me.show_error("Danh sách không còn kênh này.", false, "Thử lại");
                return;
            }
            {
                let mut st = me.st.borrow_mut();
                st.index = index;
                st.total = d(&ch, "total") as usize;
                st.ch = ch;
                st.source = 0;
                st.list_checked = false;
                st.reopens = 0;
            }
            let urls = me.urls();
            let mut src = 0;
            while src + 1 < urls.len() && !s(&urls[src], "bad").is_empty() {
                src += 1;
            }
            me.st.borrow_mut().source = src;
            me.open_source();
            if me.panel.is_visible() {
                me.build_panel(false);
            }
        });
    }

    fn step(self: &Rc<Self>, delta: i64) {
        let (i, n) = (self.st.borrow().index as i64, self.st.borrow().total as i64);
        if n < 2 {
            return;
        }
        self.play_at(((i + delta + n) % n) as usize);
        self.bump_hide();
    }

    fn next_source(self: &Rc<Self>) {
        let n = self.urls().len();
        if n < 2 {
            return;
        }
        {
            let mut st = self.st.borrow_mut();
            st.source = (st.source + 1) % n;
            st.reopens = 0;
        }
        self.open_source();
    }

    fn open_source(self: &Rc<Self>) {
        let t = {
            let mut st = self.st.borrow_mut();
            st.token += 1;
            st.started = false;
            st.icy = None;
            st.radio_desc = None;
            st.delay = 0.0;
            st.paused_at = 0;
            st.waiting_retry = false;
            st.error_shown = false;
            st.token
        };
        let Some(n) = self.native() else { return };
        n.stop();
        let ch = self.st.borrow().ch.clone();
        self.set_radio(b(&ch, "radio"));
        self.update_labels();
        let urls = self.urls();
        let source = self.st.borrow().source;
        let Some(src) = urls.get(source).cloned() else {
            self.show_error(&format!("{} không có địa chỉ phát.", s(&ch, "n")), false, "Thử lại");
            return;
        };
        let url = s(&src, "url");
        if let Some(bad) = opt(&src, "bad") {
            self.source_failed(&bad, true, t);
            return;
        }
        if iptv::is_placeholder(&url) {
            self.source_failed("Danh sách chưa có link phát (đang để hình «không có tín hiệu»).", false, t);
            return;
        }
        self.show_loading(&format!("Đang mở {}…", s(&ch, "n")));
        cbtv::log::d("tv", &format!("{} (nguồn {}/{}) {url}", s(&ch, "n"), source + 1, urls.len()));
        self.st.borrow_mut().opened_at = now_ms();
        n.load_live(&url, opt(&src, "referer").as_deref(), opt(&src, "ua").as_deref());
    }

    // ---- Mỗi giây ----

    fn tick(self: &Rc<Self>) {
        let Some(n) = self.native() else { return };
        let ticks = {
            let mut st = self.st.borrow_mut();
            st.ticks += 1;
            st.ticks
        };
        let state = n.state();
        let started = self.st.borrow().started;
        let playing = started && !state.paused && !state.waiting;
        crate::limits::tick(playing, now_ms());
        if self.check_limit() {
            return;
        }
        let ch = self.st.borrow().ch.clone();
        let (waiting_retry, error_shown, checking, token) = {
            let st = self.st.borrow();
            (st.waiting_retry, st.error_shown, st.checking, st.token)
        };
        if !ch.is_null() && !waiting_retry && !error_shown {
            if !started {
                if let Some(e) = &state.err {
                    self.source_failed(&format!("Không mở được luồng ({e})."), false, token);
                } else if state.ready && !checking {
                    self.on_started(state.d);
                } else if now_ms() - self.st.borrow().opened_at > 25_000 {
                    self.source_failed("Máy chủ của kênh không trả lời (quá 25 giây).", false, token);
                }
            } else if state.err.is_some() {
                self.reopen_later("đứt");
            } else if state.ended {
                if b(&ch, "vod") {
                    self.show_error(&format!("Đã xem hết {}.", s(&ch, "n")), true, "Xem lại");
                } else {
                    self.reopen_later("hết");
                }
            }
        }
        if self.st.borrow().started {
            let (reopens, sa) = (self.st.borrow().reopens, self.st.borrow().started_at);
            if playing && reopens > 0 && now_ms() - sa > 60_000 {
                self.st.borrow_mut().reopens = 0;
            }
            self.radio_tick();
        }
        let tm = cbtv::util::local_tm_of(now_ms() / 1000);
        self.clock.set_text(&format!("{}{:02}:{:02}", if state.waiting { "Đang tải…  " } else { "" }, tm.tm_hour, tm.tm_min));
        self.update_badge(&state);
        if b(&ch, "vod") || ticks % 15 == 0 {
            self.update_programme(Some(&state));
        }
    }

    fn on_started(self: &Rc<Self>, dur: f64) {
        let ch = self.st.borrow().ch.clone();
        // Danh sách phát là đoạn phim ngắn có hồi kết (hình chờ) — mpv báo độ dài cả cho luồng trực tiếp: đọc danh sách phát
        let hls = self.native().map(|n| n.live_info().6.as_deref() == Some("hls")).unwrap_or(false);
        if !b(&ch, "vod") && dur > 0.0 && dur < 120.0 && hls {
            let src = self.urls().get(self.st.borrow().source).cloned().unwrap_or(Value::Null);
            let t = self.st.borrow().token;
            self.st.borrow_mut().checking = true;
            let me = self.clone();
            let (url, r, u) = (s(&src, "url"), opt(&src, "referer"), opt(&src, "ua"));
            ui::spawn(async move { iptv::check_placeholder(&url, r.as_deref(), u.as_deref()).await }, move |ph| {
                me.st.borrow_mut().checking = false;
                if me.st.borrow().token != t || !me.st.borrow().open {
                    return;
                }
                if ph {
                    me.source_failed("Kênh đang phát hình chờ (đoạn phim ngắn), chưa có luồng trực tiếp.", false, t);
                } else {
                    me.mark_started();
                }
            });
            return;
        }
        self.mark_started();
    }

    fn mark_started(self: &Rc<Self>) {
        let ch = self.st.borrow().ch.clone();
        {
            let mut st = self.st.borrow_mut();
            st.started = true;
            st.started_at = now_ms();
            st.list_checked = false;
        }
        self.hide_status();
        let k = s(&ch, "k");
        ui::spawn(async move { iptv::played(&k).await }, |_| {});
        cbtv::log::d("tv", &format!("{} đang phát (nguồn {})", s(&ch, "n"), self.st.borrow().source + 1));
        self.set_controls(true);
    }

    fn reopen_later(self: &Rc<Self>, why: &str) {
        let ch = self.st.borrow().ch.clone();
        let reopens = {
            let mut st = self.st.borrow_mut();
            st.reopens += 1;
            st.started = false;
            st.reopens
        };
        cbtv::log::d("tv", &format!("luồng {} {why} — mở lại lần {reopens}", s(&ch, "n")));
        if reopens > 5 {
            let t = self.st.borrow().token;
            self.source_failed("Luồng liên tục bị đứt.", false, t);
            return;
        }
        // Bỏ luồng hỏng ngay (lỗi cũ không bị nhịp kiểm tra sau hiểu thành «không mở được»), chờ 1 giây rồi mở lại
        let t = {
            let mut st = self.st.borrow_mut();
            st.token += 1;
            st.opened_at = now_ms();
            st.token
        };
        if let Some(n) = self.native() {
            n.stop();
        }
        self.show_loading("Đang nối lại…");
        let me = self.clone();
        ui::after(1000, move || {
            if me.st.borrow().token == t && me.st.borrow().open {
                me.open_source();
            }
        });
    }

    fn source_failed(self: &Rc<Self>, reason: &str, permanent: bool, t: u64) {
        if self.st.borrow().token != t || !self.st.borrow().open {
            return;
        }
        if let Some(n) = self.native() {
            n.stop();
        }
        let ch = self.st.borrow().ch.clone();
        let urls = self.urls();
        let name = s(&ch, "n");
        let source = self.st.borrow().source;
        if iptv::auto_source() && source + 1 < urls.len() {
            cbtv::log::d("tv", &format!("{name} nguồn {} lỗi ({reason}) — sang nguồn {}", source + 1, source + 2));
            {
                let mut st = self.st.borrow_mut();
                st.source += 1;
                st.reopens = 0;
            }
            self.open_source();
            return;
        }
        let now = iptv::now_sec();
        let m = s(&ch, "match");
        let usable = urls.iter().any(|u| s(u, "bad").is_empty());
        if usable && matches!(m.as_str(), "later" | "soon" | "live") {
            let kick = d(&ch, "kick");
            let msg = if now < kick {
                format!("Trận chưa bắt đầu — bóng lăn lúc {}.\nKênh chưa lên sóng, tự thử lại sau 20 giây…", iptv::kick_text(kick, now))
            } else {
                "Trận đang đá nhưng kênh chưa phát hình.\nTự thử lại sau 20 giây…".to_string()
            };
            cbtv::log::d("tv", &format!("{name} chưa có hình ({reason}) — chờ 20 s"));
            self.show_error(&msg, true, "Thử lại");
            self.st.borrow_mut().waiting_retry = true;
            let me = self.clone();
            ui::after(20_000, move || {
                if me.st.borrow().token != t || !me.st.borrow().open || me.st.borrow().started {
                    return;
                }
                me.refresh_then_retry();
            });
            return;
        }
        let text = format!("{name} không phát được.\n{reason}");
        let list_url = iptv::active_list().and_then(|l| l.url).is_some();
        if !permanent && !self.st.borrow().list_checked && m == "none" && list_url {
            self.st.borrow_mut().list_checked = true;
            self.show_loading("Đang kiểm tra link mới…");
            let me = self.clone();
            self.refresh_channel(600, move |changed| {
                if changed {
                    me.retry_from_first();
                } else if me.st.borrow().token == t {
                    me.show_error(&text, true, "Thử lại");
                }
            });
            return;
        }
        self.show_error(&text, !permanent, "Thử lại");
    }

    /// Tải lại danh sách nếu cũ hơn `age` giây, lấy bản mới của kênh đang xem (cùng khoá). done(true) = nguồn vừa đổi.
    fn refresh_channel(self: &Rc<Self>, age: i64, done: impl FnOnce(bool) + 'static) {
        let (filter, key) = {
            let st = self.st.borrow();
            (st.filter.clone(), s(&st.ch, "k"))
        };
        let me = self.clone();
        ui::spawn(
            async move {
                let _ = iptv::refresh_if_older_than(age).await;
                let i = iptv::index_of(&filter, Some(&key), None).await;
                if i < 0 {
                    return None;
                }
                Some((i as usize, iptv::at(&filter, i as usize).await))
            },
            move |r| {
                let Some((i, fresh)) = r.filter(|(_, f)| !f.is_null()) else {
                    done(false);
                    return;
                };
                let before: Vec<String> = me.urls().iter().map(|u| s(u, "url")).collect();
                {
                    let mut st = me.st.borrow_mut();
                    st.index = i;
                    st.ch = fresh;
                }
                let after: Vec<String> = me.urls().iter().map(|u| s(u, "url")).collect();
                done(before != after);
            },
        );
    }

    fn refresh_then_retry(self: &Rc<Self>) {
        let me = self.clone();
        self.refresh_channel(120, move |_| me.retry_from_first());
    }

    fn retry_from_first(self: &Rc<Self>) {
        let urls = self.urls();
        let mut src = 0;
        while src + 1 < urls.len() && !s(&urls[src], "bad").is_empty() {
            src += 1;
        }
        {
            let mut st = self.st.borrow_mut();
            st.source = src;
            st.reopens = 0;
        }
        self.open_source();
    }

    fn retry(self: &Rc<Self>) {
        let ch = self.st.borrow().ch.clone();
        if ch.is_null() {
            return;
        }
        if b(&ch, "vod") && self.status_text.text().starts_with("Đã xem hết") {
            self.open_source();
            return;
        }
        self.show_loading("Đang kiểm tra link mới…");
        if d(&ch, "kick") > 0.0 {
            self.refresh_then_retry();
            return;
        }
        if iptv::active_list().and_then(|l| l.url).is_none() {
            self.st.borrow_mut().reopens = 0;
            self.open_source();
            return;
        }
        let me = self.clone();
        self.refresh_channel(600, move |changed| {
            if changed {
                me.retry_from_first();
            } else {
                me.st.borrow_mut().reopens = 0;
                me.open_source();
            }
        });
    }

    // ---- Phát / dừng ----

    fn toggle_play(self: &Rc<Self>) {
        let Some(n) = self.native() else { return };
        if !self.st.borrow().started {
            self.st.borrow_mut().reopens = 0;
            self.open_source();
            return;
        }
        let vod = b(&self.st.borrow().ch, "vod");
        let state = n.state();
        if !state.paused {
            n.cmd("pause", None);
            self.st.borrow_mut().paused_at = now_ms();
        } else {
            if self.st.borrow().radio && !vod {
                self.open_source();
                return;
            }
            let pa = self.st.borrow().paused_at;
            if pa > 0 && !vod {
                self.st.borrow_mut().delay += (now_ms() - pa) as f64 / 1000.0;
            }
            self.st.borrow_mut().paused_at = 0;
            n.cmd("play", None);
        }
        self.bump_hide();
    }

    fn go_live(self: &Rc<Self>) {
        self.st.borrow_mut().reopens = 0;
        self.open_source();
    }

    fn update_badge(&self, state: &crate::native::State) {
        let st = self.st.borrow();
        let vod = b(&st.ch, "vod");
        let text = if vod {
            if !st.started { "PHIM".to_string() } else if state.paused { "TẠM DỪNG".into() } else { "▶ PHIM".into() }
        } else if !st.started {
            "CHƯA PHÁT".into()
        } else if state.paused {
            "TẠM DỪNG".into()
        } else if st.delay > 8.0 {
            format!("CHẬM {}", cbtv::util::format_time(st.delay))
        } else {
            "● TRỰC TIẾP".into()
        };
        self.badge.set_text(&text);
        self.btn_live.set_visible(st.started && !vod && (st.delay > 8.0 || state.paused));
        self.btn_play.set_label(if st.started && !state.paused { "Tạm dừng" } else { "Phát" });
    }

    // ---- Nhãn ----

    fn programmes(&self) -> (Option<Value>, Option<Value>) {
        let now = iptv::now_sec();
        let st = self.st.borrow();
        let Some(all) = st.ch.get("programmes").and_then(|p| p.as_array()) else { return (None, None) };
        (
            all.iter().find(|p| d(p, "s") <= now && now < d(p, "e")).cloned(),
            all.iter().find(|p| d(p, "s") > now).cloned(),
        )
    }

    fn update_labels(&self) {
        let ch = self.st.borrow().ch.clone();
        self.num.set_text(&s(&ch, "num"));
        let urls = self.urls();
        self.btn_source.set_label(&format!("Nguồn {}/{}", self.st.borrow().source + 1, urls.len()));
        self.btn_source.set_visible(urls.len() > 1);
        self.btn_fav.set_label(if b(&ch, "fav") { "★" } else { "☆" });
        self.btn_guide.set_visible(ch.get("programmes").and_then(|p| p.as_array()).map(|a| !a.is_empty()).unwrap_or(false));
        self.panel_title.set_text(&format!("{} · {} kênh", iptv::active_list().map(|l| l.name).unwrap_or_default(), self.st.borrow().total));
        self.update_programme(self.native().map(|n| n.state()).as_ref());
        if self.st.borrow().radio {
            self.update_radio_card();
        }
    }

    fn update_programme(&self, state: Option<&crate::native::State>) {
        let ch = self.st.borrow().ch.clone();
        if ch.is_null() {
            return;
        }
        let now = iptv::now_sec();
        let (p, n) = self.programmes();
        let name = s(&ch, "n");
        self.title.set_text(&match &p {
            Some(p) => format!("{name} · {}", s(p, "t")),
            None => name.clone(),
        });
        self.prog.set_text(&p.as_ref().map(|p| s(p, "t")).unwrap_or(name));
        let mut frac = -1.0;
        let started = self.st.borrow().started;
        if let (true, Some(st), true) = (b(&ch, "vod"), state, started) {
            if st.d > 0.0 {
                self.time.set_text(&format!(
                    "{} / {} · ◀ ▶ tua 10 giây",
                    cbtv::util::format_time(st.t),
                    cbtv::util::format_time(st.d)
                ));
                frac = st.t / st.d;
            }
        } else if let Some(p) = &p {
            let e = d(p, "e");
            self.time.set_text(&format!(
                "{}–{} · còn {} phút",
                iptv::clock(d(p, "s")),
                iptv::clock(e),
                ((e - now) / 60.0).ceil().max(1.0) as i64
            ));
            frac = (now - d(p, "s")) / (e - d(p, "s")).max(1.0);
        } else if let Some(ml) = opt(&ch, "matchLine") {
            self.time.set_text(&format!("{} · {ml}", s(&ch, "g")));
            if s(&ch, "match") == "live" {
                frac = (now - d(&ch, "kick")) / (d(&ch, "dur") * 60.0);
            }
        } else {
            let radio = if self.st.borrow().radio { " · 📻 radio" } else { "" };
            self.time.set_text(&format!("{}{radio} · chưa có lịch phát sóng", s(&ch, "g")));
        }
        self.next.set_text(&n.map(|n| format!("Tiếp theo: {} {}", iptv::clock(d(&n, "s")), s(&n, "t"))).unwrap_or_default());
        self.progress.set_visible(frac >= 0.0);
        if frac >= 0.0 {
            self.progress.set_fraction(frac.clamp(0.0, 1.0));
        }
    }

    // ---- Radio ----

    fn set_radio(&self, on: bool) {
        let was = self.st.borrow().radio;
        self.st.borrow_mut().radio = on;
        if on && !was {
            self.set_controls(true);
        }
        self.show_stage();
        if on {
            self.update_radio_card();
        }
    }

    fn update_radio_card(&self) {
        let ch = self.st.borrow().ch.clone();
        self.radio_name.set_text(&s(&ch, "n"));
        let (p, _) = self.programmes();
        // Đài chỉ gửi lại tên đài làm «bài đang phát» (BBC…): bỏ, khỏi lặp tên ba lần
        let name = s(&ch, "n");
        let icy = self.st.borrow().icy.clone().filter(|t| t.to_lowercase() != name.to_lowercase());
        let song = match &icy {
            Some(t) => format!("♪ {t}"),
            None => p.map(|p| s(&p, "t")).unwrap_or_default(),
        };
        self.radio_song.set_text(&song);
        self.radio_song.set_visible(!song.is_empty());
        self.radio_info.set_text(&match &self.st.borrow().radio_desc {
            Some(x) => format!("📻 Radio · {x}"),
            None => "📻 Radio".into(),
        });
        let logo = s(&ch, "logo");
        self.radio_icon.set_visible(logo.is_empty());
        if !logo.is_empty() {
            let img = self.radio_logo.downgrade();
            let px = crate::css::px(150.0);
            crate::images::load(&logo, px, px, move |p| {
                if let (Some(p), Some(i)) = (p, img.upgrade()) {
                    i.set_from_pixbuf(Some(&p));
                }
            });
        } else {
            self.radio_logo.clear();
        }
    }

    /// Luồng không có hình (đài HLS như VOV, Icecast) → kiểu radio; có hình trở lại thì thôi. Tên bài ICY của đài.
    fn radio_tick(&self) {
        let Some(n) = self.native() else { return };
        let ch = self.st.borrow().ch.clone();
        let (has_video, icy, codec, kbps, _, _, _) = n.live_info();
        let want = !has_video && !b(&ch, "vod") && (b(&ch, "radio") || now_ms() - self.st.borrow().started_at > 4000);
        if want != self.st.borrow().radio {
            cbtv::log::d("tv", &format!("{} {}", s(&ch, "n"), if want { "chỉ có tiếng — hiện kiểu đài radio" } else { "có hình — thôi kiểu radio" }));
            self.set_radio(want);
        }
        if !self.st.borrow().radio {
            return;
        }
        let codec = codec.map(|c| {
            let u = c.to_uppercase();
            if u.starts_with("MP3") { "MP3".to_string() } else if u.starts_with("AAC") { "AAC".to_string() } else { u }
        });
        let desc = [codec, (kbps > 0).then(|| format!("{kbps} kbps"))].into_iter().flatten().collect::<Vec<_>>().join(" · ");
        let desc = Some(desc).filter(|x| !x.is_empty());
        let icy = icy.map(|x| x.trim().to_string());
        if icy != self.st.borrow().icy || desc != self.st.borrow().radio_desc {
            if let Some(t) = &icy {
                if Some(t) != self.st.borrow().icy.as_ref() {
                    cbtv::log::d("tv", &format!("{} đang phát «{t}»", s(&ch, "n")));
                }
            }
            {
                let mut st = self.st.borrow_mut();
                st.icy = icy;
                st.radio_desc = desc;
            }
            self.update_radio_card();
        }
    }

    // ---- Trạng thái ----

    fn show_stage(&self) {
        let status_on = self.status.is_visible();
        self.radio_card.set_visible(self.st.borrow().radio && !status_on);
    }

    fn show_loading(&self, text: &str) {
        self.status.show();
        self.spinner.show();
        self.spinner.start();
        self.status_text.set_text(text);
        self.status_buttons.hide();
        self.st.borrow_mut().error_shown = false;
        self.show_stage();
    }

    fn show_error(self: &Rc<Self>, text: &str, retry: bool, label: &str) {
        cbtv::log::d("tv", &text.replace('\n', " "));
        self.status.show();
        self.spinner.stop();
        self.spinner.hide();
        self.status_text.set_text(text);
        self.status_buttons.show_all();
        self.btn_retry.set_visible(retry);
        self.btn_retry.set_label(label);
        self.st.borrow_mut().error_shown = true;
        self.show_stage();
        self.set_controls(true);
        if let Some(id) = self.hide_timer.borrow_mut().take() {
            id.remove();
        }
        let target: gtk::Widget = if retry { self.btn_retry.clone().upcast() } else { self.status_buttons.children()[1].clone() };
        ui::after(50, move || keynav::focus_and_show(&target));
    }

    fn hide_status(&self) {
        self.status.hide();
        self.st.borrow_mut().error_shown = false;
        self.show_stage();
    }

    pub fn notice(&self, text: &str, ms: u64) {
        self.notice.set_text(text);
        if let Some(id) = self.notice_timer.borrow_mut().take() {
            id.remove();
        }
        let id = ui::after(ms, || {
            if let Some(l) = me() {
                l.notice_timer.borrow_mut().take();
                l.notice.set_text("");
            }
        });
        *self.notice_timer.borrow_mut() = Some(id);
    }

    // ---- Nút / bảng kênh ----

    fn controls(&self) -> bool {
        self.bottom.is_visible()
    }

    fn set_controls(&self, on: bool) {
        let was = self.controls();
        self.top.set_visible(on);
        self.bottom.set_visible(on);
        if on && !was && !self.panel.is_visible() && !self.st.borrow().error_shown {
            let b = self.btn_play.clone();
            ui::after(30, move || b.grab_focus());
        }
        self.bump_hide();
    }

    fn bump_hide(&self) {
        if let Some(id) = self.hide_timer.borrow_mut().take() {
            id.remove();
        }
        if !self.controls() && !self.panel.is_visible() {
            return;
        }
        let ms = if self.panel.is_visible() { 10_000 } else { 6000 };
        let id = ui::after(ms, || {
            if let Some(l) = me() {
                l.hide_timer.borrow_mut().take();
                l.auto_hide();
            }
        });
        *self.hide_timer.borrow_mut() = Some(id);
    }

    /// Không bấm gì một lúc khi đang phát: ẩn nút và bảng kênh. Radio: giữ nút.
    fn auto_hide(&self) {
        let paused = self.native().map(|n| n.state().paused).unwrap_or(false);
        let st = self.st.borrow();
        if !st.started || paused || st.error_shown {
            return;
        }
        let radio = st.radio;
        drop(st);
        self.panel.hide();
        if !radio {
            self.set_controls(false);
        }
    }

    fn toggle_panel(self: &Rc<Self>) {
        if self.panel.is_visible() {
            self.panel.hide();
            self.set_controls(true);
            self.btn_play.grab_focus();
            return;
        }
        self.panel.show_all();
        self.build_panel(true);
        self.bump_hide();
    }

    /// Bảng kênh: 100 kênh quanh kênh đang xem (danh sách lớn), ô đang xem tô màu.
    fn build_panel(self: &Rc<Self>, focus: bool) {
        let (filter, index) = (self.st.borrow().filter.clone(), self.st.borrow().index);
        let from = index.saturating_sub(40);
        let me = self.clone();
        ui::spawn(async move { iptv::page(&filter, from, 100).await }, move |page| {
            ui::clear(&me.panel_list);
            let total = d(&page, "total") as usize;
            me.panel_title.set_text(&format!("{} · {total} kênh", iptv::active_list().map(|l| l.name).unwrap_or_default()));
            if from > 0 {
                me.panel_list.pack_start(&btn("▲ Kênh trước nữa", move |l| {
                    l.st.borrow_mut().index = from.saturating_sub(60);
                    l.build_panel(true);
                }), false, false, 0);
            }
            let cur_index = me.st.borrow().index;
            let mut current: Option<gtk::Button> = None;
            for (j, c) in page.get("items").and_then(|x| x.as_array()).cloned().unwrap_or_default().into_iter().enumerate() {
                let idx = from + j;
                let sub = if !s(&c, "bad").is_empty() {
                    "Máy này không phát được".to_string()
                } else if let Some(n) = c.get("now").filter(|n| !n.is_null()) {
                    s(n, "t")
                } else if let Some(ml) = opt(&c, "matchLine") {
                    ml
                } else {
                    format!("{}{}", if b(&c, "radio") { "📻 " } else { "" }, s(&c, "g"))
                };
                let bt = btn(&format!("{}   {}\n{sub}", s(&c, "num"), s(&c, "n")), move |l| {
                    if l.st.borrow().index != idx {
                        l.play_at(idx);
                    }
                    l.bump_hide();
                });
                if let Some(lbl) = bt.child().and_then(|x| x.downcast::<gtk::Label>().ok()) {
                    lbl.set_xalign(0.0);
                }
                if idx == cur_index {
                    bt.style_context().add_class("active");
                    current = Some(bt.clone());
                }
                me.panel_list.pack_start(&bt, false, false, 0);
            }
            if from + 100 < total {
                me.panel_list.pack_start(&btn("▼ Kênh sau nữa", move |l| {
                    l.st.borrow_mut().index = (from + 140).min(total.saturating_sub(1));
                    l.build_panel(true);
                }), false, false, 0);
            }
            me.panel_list.show_all();
            if let (Some(c), true) = (current, focus) {
                ui::after(60, move || keynav::focus_and_show(&c.upcast()));
            }
        });
    }

    fn toggle_favorite(self: &Rc<Self>) {
        let ch = self.st.borrow().ch.clone();
        if ch.is_null() {
            return;
        }
        let on = !b(&ch, "fav");
        iptv::set_favorite(&s(&ch, "k"), on);
        if let Some(o) = self.st.borrow_mut().ch.as_object_mut() {
            o.insert("fav".into(), json!(on));
        }
        self.btn_fav.set_label(if on { "★" } else { "☆" });
        let n = s(&ch, "n");
        self.notice(&if on { format!("Đã thêm {n} vào Yêu thích.") } else { format!("Đã bỏ {n} khỏi Yêu thích.") }, 4000);
        self.bump_hide();
    }

    fn open_guide(self: &Rc<Self>) {
        let (f, i) = (self.st.borrow().filter.clone(), self.st.borrow().index);
        self.close();
        app().push(crate::pages::tv::guide(f, i));
    }

    // ---- Gõ số kênh ----

    fn type_digit(self: &Rc<Self>, dg: u32) {
        {
            let mut st = self.st.borrow_mut();
            if st.digits.len() >= 5 {
                st.digits.clear();
            }
            st.digits.push(char::from_digit(dg, 10).unwrap_or('0'));
        }
        self.notice(&format!("Kênh số {}_", self.st.borrow().digits), 1600);
        if let Some(id) = self.digits_timer.borrow_mut().take() {
            id.remove();
        }
        let id = ui::after(1500, || {
            if let Some(l) = me() {
                l.digits_timer.borrow_mut().take();
                l.jump_to_number();
            }
        });
        *self.digits_timer.borrow_mut() = Some(id);
    }

    fn jump_to_number(self: &Rc<Self>) {
        let num = {
            let mut st = self.st.borrow_mut();
            let n = st.digits.trim_start_matches('0').to_string();
            st.digits.clear();
            if n.is_empty() { "0".to_string() } else { n }
        };
        let filter = self.st.borrow().filter.clone();
        let me = self.clone();
        let n2 = num.clone();
        ui::spawn(async move { iptv::index_of(&filter, None, Some(&n2)).await }, move |i| {
            if i >= 0 {
                me.play_at(i as usize);
            } else {
                me.notice(&format!("Không có kênh số {num} trong danh sách đang xem."), 4000);
            }
        });
    }

    // ---- Giới hạn giờ xem ----

    fn check_limit(self: &Rc<Self>) -> bool {
        match crate::limits::blocked() {
            None => {
                let (started, warned) = (self.st.borrow().started, self.st.borrow().limit_warned);
                if started && !warned {
                    if let Some(r) = crate::limits::remaining().filter(|r| *r > 0 && *r <= 300) {
                        self.st.borrow_mut().limit_warned = true;
                        self.notice(&format!("Còn {} xem hôm nay ({}).", crate::limits::minutes_text(r), cbtv::prefs::current_profile().name), 8000);
                    }
                }
                false
            }
            Some(bl) => {
                let (f, i) = (self.st.borrow().filter.clone(), self.st.borrow().index);
                self.close();
                crate::limits::limit_reached_then(bl, Rc::new(move || app().play_live(f.clone(), i)));
                true
            }
        }
    }

    // ---- Phím ----

    pub fn handle_key(self: &Rc<Self>, ev: &gdk::EventKey) -> bool {
        use gdk::keys::constants as k;
        let key = ev.keyval();
        self.bump_hide();
        let vod = b(&self.st.borrow().ch, "vod");
        if key == k::Page_Up || key == k::AudioNext {
            self.step(1);
            return true;
        }
        if key == k::Page_Down || key == k::AudioPrev {
            self.step(-1);
            return true;
        }
        if key == k::space || key == k::AudioPlay || key == k::AudioPause {
            self.toggle_play();
            return true;
        }
        if key == k::g || key == k::G {
            if self.btn_guide.is_visible() {
                self.open_guide();
            }
            return true;
        }
        if key == k::m || key == k::M || key == k::Menu {
            self.toggle_panel();
            return true;
        }
        if let Some(c) = key.to_unicode().and_then(|c| c.to_digit(10)) {
            self.type_digit(c);
            return true;
        }
        if key == k::Escape || key == k::Back || key == k::BackSpace {
            if self.panel.is_visible() {
                self.toggle_panel();
            } else if self.controls() && self.st.borrow().started {
                self.set_controls(false);
            } else {
                self.close();
            }
            return true;
        }
        let Some(dir) = keynav::dir_of(&key) else {
            if (key == k::Return || key == k::KP_Enter) && !self.controls() && !self.panel.is_visible() {
                self.set_controls(true);
                return true;
            }
            return false;
        };
        // Đang ẩn nút / bảng: phím mũi tên là lệnh của trình phát
        if !self.controls() && !self.panel.is_visible() && !self.st.borrow().error_shown {
            match dir {
                Dir::Up => self.step(-1),
                Dir::Down => self.step(1),
                Dir::Left => {
                    if vod {
                        self.seek(-10.0)
                    } else {
                        self.toggle_panel()
                    }
                }
                Dir::Right => {
                    if vod {
                        self.seek(10.0)
                    } else {
                        self.set_controls(true)
                    }
                }
            }
            return true;
        }
        let root: gtk::Widget = self.root.clone().upcast();
        let focused = app().window.focused_widget().filter(|f| keynav::is_inside(f, &root));
        match focused {
            Some(f) => {
                let panel: gtk::Widget = self.panel.clone().upcast();
                let area = if self.panel.is_visible() && keynav::is_inside(&f, &panel) && matches!(dir, Dir::Up | Dir::Down) { panel } else { root };
                if let Some(n) = keynav::next(&area, &f, dir) {
                    keynav::focus_and_show(&n);
                }
            }
            None => {
                if let Some(f) = keynav::first(&root) {
                    keynav::focus_and_show(&f);
                }
            }
        }
        true
    }

    fn seek(&self, by: f64) {
        let Some(n) = self.native() else { return };
        if !self.st.borrow().started {
            return;
        }
        let state = n.state();
        if state.d <= 0.0 {
            return;
        }
        n.cmd("seekTo", Some((state.t + by).clamp(0.0, state.d)));
        self.set_controls(true);
    }

    /// Cổng gỡ lỗi: kênh, nguồn, đang phát, radio, trạng thái.
    pub fn debug_status(&self) -> String {
        let st = self.st.borrow();
        let state = self.native().map(|n| n.state());
        let info = self.native().map(|n| n.live_info());
        format!(
            "kênh {} «{}» ({}/{}) nguồn {}/{} | {} | {} | t={:.1} d={:.1} err={:?} | hình {}x{} tiếng {:?} {}kbps | radio={} «{}» | trạng thái: {}",
            s(&st.ch, "num"),
            s(&st.ch, "n"),
            st.index + 1,
            st.total,
            st.source + 1,
            st.ch.get("urls").and_then(|u| u.as_array()).map(|a| a.len()).unwrap_or(0),
            if st.started { "đang phát" } else { "chưa phát" },
            self.badge.text(),
            state.as_ref().map(|x| x.t).unwrap_or(0.0),
            state.as_ref().map(|x| x.d).unwrap_or(0.0),
            state.as_ref().and_then(|x| x.err.clone()),
            info.as_ref().map(|x| x.4).unwrap_or(0),
            info.as_ref().map(|x| x.5).unwrap_or(0),
            info.as_ref().and_then(|x| x.2.clone()),
            info.as_ref().map(|x| x.3).unwrap_or(0),
            st.radio,
            st.icy.clone().unwrap_or_default(),
            if self.status.is_visible() { self.status_text.text().replace('\n', " ") } else { "—".into() }
        )
    }
}
