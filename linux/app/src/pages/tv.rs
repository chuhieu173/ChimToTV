//! Truyền hình · Radio (IPTV): danh sách kênh M3U người xem tự thêm (app không kèm sẵn kênh) — nhóm, tìm tên / số kênh, ★ yêu
//! thích, chương trình đang phát, trạng thái trận; lịch phát sóng; cài đặt. Bản Windows: UI/TvPages.cs; lõi: cbtv::iptv.

use super::{Page, PageBase};
use crate::app::app;
use crate::css::px;
use crate::keynav;
use crate::ui;
use cbtv::iptv::{self, Filter};
use gtk::prelude::*;
use serde_json::Value;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

const PAGE: usize = 120;

fn s(v: &Value, k: &str) -> String {
    v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string()
}
fn d(v: &Value, k: &str) -> f64 {
    v.get(k).and_then(|x| x.as_f64()).unwrap_or(0.0)
}
fn flag(v: &Value, k: &str) -> bool {
    v.get(k).and_then(|x| x.as_bool()).unwrap_or(false)
}

pub struct TvPage {
    base: PageBase,
    search: gtk::Entry,
    filter: RefCell<Filter>,
    offset: Cell<usize>,
    favs_chosen: Cell<bool>,
    version: Cell<u64>,
    cards: gtk::FlowBox,
    info: gtk::Label,
}

pub fn new() -> Rc<dyn Page> {
    let search = ui::entry();
    search.set_width_chars(26);
    search.set_placeholder_text(Some("Tìm kênh / số kênh"));
    let p = Rc::new(TvPage {
        base: PageBase::new("tv"),
        search,
        filter: RefCell::new(Filter::default()),
        offset: Cell::new(0),
        favs_chosen: Cell::new(false),
        version: Cell::new(u64::MAX),
        cards: ui::flow(12.0, 12.0),
        info: ui::dim(""),
    });
    p.base.keep(&p.search);
    let weak = Rc::downgrade(&p);
    p.search.connect_changed(move |e| {
        let Some(p) = weak.upgrade() else { return };
        let q = e.text().trim().to_string();
        let weak2 = Rc::downgrade(&p);
        ui::after(450, move || {
            let Some(p) = weak2.upgrade() else { return };
            if p.search.text().trim() != q {
                return; // còn gõ tiếp
            }
            p.filter.borrow_mut().q = q;
            p.offset.set(0);
            p.load_cards(false);
        });
    });
    // Mỗi giây: đang tải danh sách / lịch thì cập nhật dòng trạng thái; dữ liệu đổi thì dựng lại. Mỗi 30 giây: vẽ lại giờ trận /
    // chương trình, tự làm mới danh sách khi quá hạn.
    let weak = Rc::downgrade(&p);
    let ticks = Cell::new(0u32);
    glib::timeout_add_local(std::time::Duration::from_secs(1), move || {
        let Some(p) = weak.upgrade() else { return glib::ControlFlow::Break };
        if !p.base.body.is_mapped() {
            return glib::ControlFlow::Continue;
        }
        ticks.set(ticks.get() + 1);
        let st = iptv::status();
        let v = st["version"].as_u64().unwrap_or(0);
        if v != p.version.get() {
            p.rebuild();
        } else {
            p.update_info(&st);
        }
        if ticks.get() % 30 == 0 {
            p.load_cards(true);
            ui::spawn(async { iptv::auto_refresh().await }, |_| {});
        }
        glib::ControlFlow::Continue
    });
    p
}

fn refresh_list(force: bool) {
    ui::spawn(async move { iptv::refresh(force).await }, |r| {
        if let Err(e) = r {
            app().toast(&cbtv::util::friendly(&e));
        }
    });
}

impl TvPage {
    fn update_info(&self, st: &Value) {
        let Some(l) = st.get("active").filter(|x| !x.is_null()) else {
            self.info.set_text("");
            return;
        };
        let mut t = s(l, "name");
        let status = s(st, "status");
        if !status.is_empty() {
            t += &format!(" · {status}");
        } else {
            if d(l, "count") > 0.0 {
                t += &format!(" · {} kênh", d(l, "count") as i64);
            }
            if d(l, "updated") > 0.0 {
                t += &format!(" · cập nhật {}", iptv::clock(d(l, "updated") / 1000.0));
            }
            if cbtv::prefs::kids() {
                t += " · hồ sơ trẻ em: kênh thiếu nhi";
            }
        }
        self.info.set_text(&t);
    }

    fn rebuild(self: &Rc<Self>) {
        let st = iptv::status();
        self.version.set(st["version"].as_u64().unwrap_or(0));
        let b = &self.base;
        b.clear();
        let head = ui::hbox(14.0);
        head.pack_start(&ui::header("Truyền hình · Radio"), false, false, 0);
        if let Some(p) = self.info.parent().and_then(|p| p.downcast::<gtk::Container>().ok()) {
            p.remove(&self.info);
        }
        head.pack_start(&self.info, false, false, 0);
        b.add(&head);
        self.update_info(&st);
        if st.get("active").map(|x| x.is_null()).unwrap_or(true) {
            b.add(&ui::dim("Chưa có danh sách kênh. App không kèm sẵn kênh: thêm địa chỉ danh sách M3U / M3U8 (hoặc tệp .m3u) mà bạn có quyền xem."));
            let me = self.clone();
            b.add(&ui::row(&[ui::pill("+  Thêm danh sách kênh", move || ask_add(Rc::new({
                let me = me.clone();
                move || me.rebuild()
            })))
            .upcast()]));
            let body = b.body.clone();
            ui::after(60, move || {
                if let Some(f) = keynav::first(body.upcast_ref()) {
                    keynav::focus_and_show(&f);
                }
            });
            return;
        }
        let me = self.clone();
        let me2 = self.clone();
        b.add(&ui::row(&[
            self.search.clone().upcast(),
            ui::pill("Đổi danh sách", move || me.choose_list()).upcast(),
            ui::pill("⚙  Cài đặt Truyền hình", move || {
                let _ = &me2;
                app().push(settings());
            })
            .upcast(),
        ]));
        let me = self.clone();
        ui::spawn(async { iptv::groups().await }, move |g| me.show_groups(g));
    }

    fn show_groups(self: &Rc<Self>, g: Value) {
        let total = d(&g, "total") as i64;
        let favs = d(&g, "favs") as i64;
        if !self.favs_chosen.get() && total > 0 {
            self.favs_chosen.set(true);
            if favs > 0 {
                let mut f = self.filter.borrow_mut();
                f.favs = true;
                f.group = None;
            }
        }
        let f = self.filter.borrow().clone();
        let mut pills: Vec<gtk::Widget> = Vec::new();
        let mk = |me: &Rc<Self>, text: String, active: bool, group: Option<u32>, fav: bool| -> gtk::Widget {
            let me = me.clone();
            let p = ui::pill_tag(&text, active.then_some("active"), move || {
                {
                    let mut f = me.filter.borrow_mut();
                    f.favs = fav;
                    f.group = group;
                }
                me.offset.set(0);
                me.rebuild();
            });
            // Trong dải cuộn ngang: một dòng (nút pill mặc định xuống dòng)
            if let Some(l) = p.child().and_then(|c| c.downcast::<gtk::Label>().ok()) {
                l.set_line_wrap(false);
            }
            p.upcast()
        };
        pills.push(mk(self, format!("★ Yêu thích  {favs}"), f.favs, None, true));
        pills.push(mk(self, format!("Tất cả  {total}"), !f.favs && f.group.is_none(), None, false));
        for x in g.get("groups").and_then(|a| a.as_array()).cloned().unwrap_or_default() {
            let id = d(&x, "id") as u32;
            pills.push(mk(self, format!("{}  {}", s(&x, "name"), d(&x, "count") as i64), !f.favs && f.group == Some(id), Some(id), false));
        }
        // Một hàng cuộn ngang (◄ ► đi qua các nhóm) — danh sách Xtream có vài trăm nhóm
        self.base.add(&ui::strip(&ui::dim("Nhóm kênh").upcast(), pills, None));
        if let Some(p) = self.cards.parent().and_then(|p| p.downcast::<gtk::Container>().ok()) {
            p.remove(&self.cards);
        }
        self.base.add(&self.cards);
        self.load_cards(false);
    }

    fn load_cards(self: &Rc<Self>, keep: bool) {
        let focused_key = if keep {
            app().window.focused_widget().and_then(|w| w.widget_name().strip_prefix("tv:").map(String::from))
        } else {
            None
        };
        let f = self.filter.borrow().clone();
        let off = self.offset.get();
        let me = self.clone();
        ui::spawn(async move { iptv::page(&f, off, PAGE).await }, move |page| {
            ui::clear(&me.cards);
            let total = d(&page, "total") as usize;
            let items = page.get("items").and_then(|x| x.as_array()).cloned().unwrap_or_default();
            let mut focus_to: Option<gtk::Widget> = None;
            for (j, c) in items.iter().enumerate() {
                let w = me.card(c, off + j);
                if focused_key.as_deref() == Some(&s(c, "k")) {
                    focus_to = Some(w.clone());
                }
                ui::add_flow(&me.cards, &w);
            }
            if items.is_empty() {
                let f = me.filter.borrow();
                let msg = if !f.q.is_empty() {
                    format!("Không có kênh nào khớp «{}».", f.q)
                } else if f.favs {
                    "Chưa có kênh yêu thích — nhấn phải chuột / phím Menu trên ô kênh để thêm.".into()
                } else if iptv::loading() {
                    "Đang tải danh sách kênh…".into()
                } else {
                    "Nhóm này không có kênh.".into()
                };
                ui::add_flow(&me.cards, &ui::dim(&msg).upcast());
            }
            if total > PAGE {
                let mut nav: Vec<gtk::Widget> = Vec::new();
                if off > 0 {
                    let m = me.clone();
                    nav.push(ui::pill("‹ Trang trước", move || {
                        m.offset.set(off.saturating_sub(PAGE));
                        m.load_cards(false);
                    }).upcast());
                }
                nav.push(ui::dim(&format!("Kênh {}–{} / {total}", off + 1, (off + PAGE).min(total))).upcast());
                if off + PAGE < total {
                    let m = me.clone();
                    nav.push(ui::pill("Trang sau ›", move || {
                        m.offset.set(off + PAGE);
                        m.load_cards(false);
                    }).upcast());
                }
                for w in nav {
                    ui::add_flow(&me.cards, &w);
                }
            }
            me.cards.show_all();
            if let Some(w) = focus_to {
                ui::after(40, move || keynav::focus_and_show(&w));
            }
        });
    }

    fn card(self: &Rc<Self>, c: &Value, index: usize) -> gtk::Widget {
        let now = iptv::now_sec();
        let btn = gtk::Button::new();
        btn.style_context().add_class("pill");
        btn.set_widget_name(&format!("tv:{}", s(c, "k")));
        btn.set_size_request(px(300.0), px(118.0));
        let v = ui::vbox(4.0);
        let top = ui::hbox(10.0);
        let logo = gtk::Image::new();
        logo.set_size_request(px(64.0), px(40.0));
        if !s(c, "logo").is_empty() {
            let weak = logo.downgrade();
            crate::images::load(&s(c, "logo"), px(64.0), px(40.0), move |p| {
                if let (Some(p), Some(i)) = (p, weak.upgrade()) {
                    i.set_from_pixbuf(Some(&p));
                }
            });
        }
        top.pack_start(&logo, false, false, 0);
        let name = ui::label(&format!("{}  {}", s(c, "num"), s(c, "n")), &[], true);
        // FlowBox của GTK3 xếp theo cột rộng bằng ô rộng nhất: giới hạn bề rộng chữ để ô giữ ~300 px
        name.set_max_width_chars(24);
        name.set_lines(2);
        name.set_ellipsize(pango::EllipsizeMode::End);
        name.set_hexpand(true);
        top.pack_start(&name, true, true, 0);
        if flag(c, "fav") {
            top.pack_start(&ui::text("★"), false, false, 0);
        }
        v.pack_start(&top, false, false, 0);
        let bad = s(c, "bad");
        let m = s(c, "match");
        let line = s(c, "matchLine");
        let g = if flag(c, "radio") { format!("📻 {}", s(c, "g")) } else if flag(c, "vod") { format!("🎬 {}", s(c, "g")) } else { s(c, "g") };
        let (l1, l2, frac) = if !bad.is_empty() {
            ("Máy này không phát được".to_string(), bad.clone(), -1.0)
        } else if !line.is_empty() {
            let k = s(c, "k");
            let remind = if iptv::has_reminder(&k, None, true) { "🔔 Nhắc lúc bóng lăn · " } else { "" };
            let f = if m == "live" { (now - d(c, "kick")) / (d(c, "dur") * 60.0) } else { -1.0 };
            (line.clone(), format!("{remind}{}", s(c, "g")), f)
        } else if let Some(p) = c.get("now").filter(|x| !x.is_null()) {
            let (ps, pe) = (d(p, "s"), d(p, "e"));
            let n = c.get("next").filter(|x| !x.is_null());
            (
                format!("{}   {}–{}", s(p, "t"), iptv::clock(ps), iptv::clock(pe)),
                n.map(|n| format!("Tiếp: {} {}", iptv::clock(d(n, "s")), s(n, "t"))).unwrap_or(g.clone()),
                (now - ps) / (pe - ps).max(1.0),
            )
        } else {
            (g.clone(), String::new(), -1.0)
        };
        let l1w = ui::label(&l1, &[], false);
        l1w.set_max_width_chars(32);
        v.pack_start(&l1w, false, false, 0);
        if frac >= 0.0 {
            let pb = gtk::ProgressBar::new();
            pb.set_fraction(frac.clamp(0.0, 1.0));
            v.pack_start(&pb, false, false, 0);
        }
        if !l2.is_empty() {
            let l2w = ui::dim(&l2);
            l2w.set_ellipsize(pango::EllipsizeMode::End);
            l2w.set_line_wrap(false);
            l2w.set_max_width_chars(36);
            v.pack_start(&l2w, false, false, 0);
        }
        btn.add(&v);
        btn.set_opacity(if !bad.is_empty() { 0.55 } else if m == "over" { 0.7 } else { 1.0 });
        let c1 = c.clone();
        let me = self.clone();
        btn.connect_clicked(move |_| me.open(&c1, index));
        let c2 = c.clone();
        let me = self.clone();
        btn.connect_button_release_event(move |_, ev| {
            if ev.button() == 3 {
                me.menu(&c2, index);
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        let c3 = c.clone();
        let me = self.clone();
        btn.connect_key_press_event(move |_, ev| {
            use gdk::keys::constants as k;
            let key = ev.keyval();
            if key == k::Menu || key == k::m || key == k::M {
                me.menu(&c3, index);
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        btn.upcast()
    }

    fn open(self: &Rc<Self>, c: &Value, index: usize) {
        if let Some(bl) = crate::limits::blocked() {
            let f = self.filter.borrow().clone();
            crate::limits::limit_reached_then(bl, Rc::new(move || app().play_live(f.clone(), index)));
            return;
        }
        let f = self.filter.borrow().clone();
        if s(c, "match") == "later" {
            let (c, me) = (c.clone(), self.clone());
            ui::local(async move {
                let kick = d(&c, "kick");
                let m = ((kick - iptv::now_sec()) / 60.0).ceil() as i64;
                let left = if m >= 24 * 60 {
                    format!("{} ngày", (m + 720) / 1440)
                } else if m >= 60 {
                    format!("{} giờ {:02} phút", m / 60, m % 60)
                } else {
                    format!("{m} phút")
                };
                let has = iptv::has_reminder(&s(&c, "k"), None, true);
                let r = app()
                    .ask_async(
                        "Trận chưa bắt đầu",
                        &format!("{}\nBóng lăn lúc {} (còn {left}).\nKênh trận đấu thường chỉ lên sóng trước giờ đá 15–30 phút.", s(&c, "n"),
                            iptv::kick_text(kick, iptv::now_sec())),
                        &[if has { "Bỏ nhắc" } else { "Nhắc lúc bóng lăn" }, "Vẫn mở", "Đóng"],
                        None,
                        0,
                    )
                    .await;
                if r == 0 {
                    me.toggle_kick(&c);
                } else if r == 1 {
                    app().play_live(f, index);
                }
            });
            return;
        }
        app().play_live(f, index);
    }

    fn toggle_kick(self: &Rc<Self>, c: &Value) {
        let on = iptv::toggle_reminder(&s(c, "k"), &s(c, "n"), &s(c, "n"), d(c, "kick"), true);
        app().toast(&if on {
            format!("Sẽ nhắc lúc bóng lăn ({}) — khi app đang mở.", iptv::kick_text(d(c, "kick"), iptv::now_sec()))
        } else {
            "Đã bỏ nhắc.".into()
        });
        self.load_cards(true);
    }

    /// Nhấn phải / phím Menu trên ô kênh.
    fn menu(self: &Rc<Self>, c: &Value, index: usize) {
        let (c, me) = (c.clone(), self.clone());
        ui::local(async move {
            let m = s(&c, "match");
            let mut acts: Vec<(String, u8)> = vec![("Xem".into(), 0)];
            if m == "later" || m == "soon" {
                acts.push((if iptv::has_reminder(&s(&c, "k"), None, true) { "Bỏ nhắc bóng lăn".into() } else { "🔔 Nhắc lúc bóng lăn".into() }, 1));
            }
            if m == "none" && !flag(&c, "vod") {
                acts.push(("Lịch phát sóng".into(), 2));
            }
            let fav = flag(&c, "fav");
            acts.push((if fav { "Bỏ khỏi Yêu thích".into() } else { "★ Thêm vào Yêu thích".into() }, 3));
            if !s(&c, "bad").is_empty() {
                acts.push(("Thử lại kênh này".into(), 4));
            }
            let mut labels: Vec<&str> = acts.iter().map(|a| a.0.as_str()).collect();
            labels.push("Huỷ");
            let r = app().ask_async(&s(&c, "n"), "", &labels, None, 0).await;
            let Some(&(_, act)) = acts.get(r.max(0) as usize).filter(|_| r >= 0) else { return };
            match act {
                0 => me.open(&c, index),
                1 => me.toggle_kick(&c),
                2 => app().push(guide(me.filter.borrow().clone(), index)),
                3 => {
                    iptv::set_favorite(&s(&c, "k"), !fav);
                    app().toast(&if fav { format!("Đã bỏ {} khỏi Yêu thích.", s(&c, "n")) } else { format!("Đã thêm {} vào Yêu thích.", s(&c, "n")) });
                }
                _ => {
                    iptv::clear_bad_for(&s(&c, "k"));
                    me.open(&c, index);
                }
            }
        });
    }

    fn choose_list(self: &Rc<Self>) {
        let me = self.clone();
        ui::local(async move {
            let lists = iptv::lists();
            let active = iptv::active_list().map(|l| l.id).unwrap_or_default();
            let mut labels: Vec<String> = lists
                .iter()
                .map(|l| format!("{}{}{}", if l.id == active { "✓ " } else { "" }, l.name, if l.count > 0 { format!("  ({} kênh)", l.count) } else { String::new() }))
                .collect();
            labels.push("+ Thêm danh sách…".into());
            labels.push("Quản lý danh sách, lịch phát sóng…".into());
            let refs: Vec<&str> = labels.iter().map(|x| x.as_str()).collect();
            let r = app().ask_async("Danh sách kênh", "", &refs, None, 0).await;
            if r < 0 {
                return;
            }
            let r = r as usize;
            if r < lists.len() {
                iptv::set_active(Some(&lists[r].id));
                me.favs_chosen.set(false);
                *me.filter.borrow_mut() = Filter::default();
                me.offset.set(0);
                me.rebuild();
                refresh_list(false);
            } else if r == lists.len() {
                let m = me.clone();
                ask_add(Rc::new(move || m.rebuild()));
            } else {
                app().push(settings());
            }
        });
    }
}

impl Page for TvPage {
    fn base(&self) -> &PageBase {
        &self.base
    }

    fn start(self: Rc<Self>) {
        self.base.loading("Đang tải…");
        self.rebuild();
        if iptv::active_list().is_some() {
            refresh_list(false);
        }
    }

    fn returned(self: Rc<Self>) {
        self.rebuild();
        ui::spawn(async { iptv::auto_refresh().await }, |_| {});
    }

    fn has_input(&self) -> bool {
        true
    }
}

/// Thêm danh sách: dán / gõ địa chỉ, hoặc chọn tệp .m3u trên máy.
pub fn ask_add(done: Rc<dyn Fn()>) {
    ui::local(async move {
        let a = app();
        // Nhiều dòng: dán một lần nhiều địa chỉ, mỗi dòng một danh sách
        // Giữ riêng bộ đệm chữ: đóng hộp thoại là ô bị huỷ (bộ đệm của ô cũng bị gỡ) — đọc chữ sau đó phải qua bản giữ này
        let url_buf = gtk::TextBuffer::new(None::<&gtk::TextTagTable>);
        let url = gtk::TextView::with_buffer(&url_buf);
        url.set_wrap_mode(gtk::WrapMode::None);
        url.set_accepts_tab(false);
        url.set_left_margin(8);
        url.set_top_margin(6);
        url.set_bottom_margin(6);
        let url_box = gtk::ScrolledWindow::new(None::<&gtk::Adjustment>, None::<&gtk::Adjustment>);
        url_box.set_policy(gtk::PolicyType::Automatic, gtk::PolicyType::Automatic);
        url_box.set_size_request(px(440.0), px(96.0));
        url_box.add(&url);
        url_box.style_context().add_class("frame");
        let url_hint = ui::dim("http://…/danh-sach.m3u — dán được nhiều địa chỉ, mỗi dòng một danh sách");
        let name = ui::entry();
        name.set_width_chars(46);
        name.set_max_length(40);
        name.set_placeholder_text(Some("Tên hiện trong app (không bắt buộc)"));
        let bx = ui::vbox(10.0);
        bx.pack_start(&url_hint, false, false, 0);
        bx.pack_start(&url_box, false, false, 0);
        bx.pack_start(&name, false, false, 0);
        let u2 = url.clone();
        ui::after(30, move || u2.grab_focus());
        let r = a
            .ask_async("Thêm danh sách kênh", "Địa chỉ danh sách M3U / M3U8 — app không kèm sẵn kênh, chỉ thêm danh sách bạn có quyền xem.",
                &["Thêm", "Chọn tệp .m3u…", "Huỷ"], Some(bx.upcast()), 0)
            .await;
        let nm = name.text().trim().to_string();
        let nm = (!nm.is_empty()).then_some(nm);
        let mut many = 0;
        let added = match r {
            0 => {
                let text = url_buf.text(&url_buf.start_iter(), &url_buf.end_iter(), false).map(|t| t.to_string()).unwrap_or_default();
                let res = iptv::add_lists(&text, nm.as_deref());
                let Some(first) = res.added.first().cloned() else {
                    a.toast(match res.existing {
                        0 => "Chưa có địa chỉ danh sách.",
                        1 => "Danh sách này đã có trong app.",
                        _ => "Các danh sách này đã có trong app.",
                    });
                    return;
                };
                many = res.added.len();
                if many > 1 || res.existing > 0 {
                    let skip = if res.existing > 0 { format!(" (bỏ qua {} đã có)", res.existing) } else { String::new() };
                    a.toast(&format!(
                        "Đã thêm {many} danh sách{skip} — đang tải «{}»; danh sách khác tải khi chọn trong «Đổi danh sách».",
                        first.name
                    ));
                }
                first
            }
            1 => {
                let dlg = gtk::FileChooserNative::new(Some("Chọn tệp danh sách kênh"), Some(&a.window), gtk::FileChooserAction::Open, Some("Mở"), Some("Huỷ"));
                let ff = gtk::FileFilter::new();
                ff.set_name(Some("Danh sách kênh (.m3u, .m3u8)"));
                for p in ["*.m3u", "*.m3u8", "*.M3U", "*.txt"] {
                    ff.add_pattern(p);
                }
                dlg.add_filter(ff);
                if dlg.run() != gtk::ResponseType::Accept {
                    return;
                }
                let Some(path) = dlg.filename() else { return };
                match iptv::add_file(&path.to_string_lossy(), nm.as_deref()) {
                    Ok(l) => l,
                    Err(e) => {
                        a.toast(&cbtv::util::friendly(&e));
                        return;
                    }
                }
            }
            _ => return,
        };
        if many <= 1 {
            a.toast(&format!("Đã thêm danh sách «{}» — đang tải kênh…", added.name));
        }
        done();
        let done2 = done.clone();
        ui::spawn(async { iptv::refresh(true).await }, move |r| {
            if let Err(e) = r {
                app().toast(&cbtv::util::friendly(&e));
            }
            done2();
        });
    });
}

// ---- Lịch phát sóng ----

pub struct GuidePage {
    base: PageBase,
    filter: Filter,
    index: usize,
    day: Cell<i64>,
    ch: RefCell<Value>,
}

pub fn guide(filter: Filter, index: usize) -> Rc<dyn Page> {
    Rc::new(GuidePage { base: PageBase::new("tv"), filter, index, day: Cell::new(0), ch: RefCell::new(Value::Null) })
}

fn day_start(offset: i64) -> f64 {
    let now = cbtv::util::now_ms() / 1000;
    let mut tm = cbtv::util::local_tm_of(now);
    tm.tm_hour = 0;
    tm.tm_min = 0;
    tm.tm_sec = 0;
    tm.tm_mday += offset as i32;
    cbtv::util::mktime_local(&mut tm) as f64
}

impl GuidePage {
    fn build(self: &Rc<Self>) {
        let b = &self.base;
        b.clear();
        let c = self.ch.borrow().clone();
        if c.is_null() {
            b.add(&ui::dim("Danh sách kênh đang chọn không còn kênh này."));
            return;
        }
        b.add(&ui::header(&s(&c, "n")));
        b.add(&ui::dim(&format!("Kênh {} · {}{}", s(&c, "num"), s(&c, "g"), if flag(&c, "fav") { " · ★ Yêu thích" } else { "" })));
        let (f, i) = (self.filter.clone(), self.index);
        let mut row: Vec<gtk::Widget> = vec![ui::pill("▶  Xem trực tiếp", move || app().play_live(f.clone(), i)).upcast()];
        for (dd, t) in [(-1i64, "Hôm qua"), (0, "Hôm nay"), (1, "Ngày mai")] {
            let me = self.clone();
            row.push(ui::pill_tag(t, (self.day.get() == dd).then_some("active"), move || {
                me.day.set(dd);
                me.build();
            }).upcast());
        }
        b.add(&ui::row(&row));
        let all = c.get("programmes").and_then(|p| p.as_array()).cloned().unwrap_or_default();
        let (from, to) = (day_start(self.day.get()), day_start(self.day.get() + 1));
        let rows: Vec<Value> = all.iter().filter(|p| d(p, "s") >= from && d(p, "s") < to).cloned().collect();
        if rows.is_empty() {
            b.add(&ui::dim(if !all.is_empty() {
                "Ngày này chưa có lịch."
            } else if iptv::epg_url().is_some() {
                "Kênh này chưa có lịch phát sóng (lịch của danh sách không có kênh này)."
            } else {
                "Danh sách kênh không ghi địa chỉ lịch phát sóng. Đặt trong Cài đặt Truyền hình."
            }));
            return;
        }
        let now = iptv::now_sec();
        let mut current: Option<gtk::Widget> = None;
        for p in rows {
            let (ps, pe) = (d(&p, "s"), d(&p, "e"));
            let live = ps <= now && now < pe;
            let future = ps > now;
            let remind = future && iptv::has_reminder(&s(&c, "k"), Some(ps), false);
            let detail = if live {
                format!("ĐANG PHÁT · còn {} phút · Enter: xem", ((pe - now) / 60.0).ceil().max(1.0) as i64)
            } else if future {
                format!("{}–{} · {}", iptv::clock(ps), iptv::clock(pe), if remind { "🔔 Đã đặt nhắc (Enter: bỏ)" } else { "Enter: Nhắc tôi" })
            } else {
                format!("{}–{}", iptv::clock(ps), iptv::clock(pe))
            };
            let (c2, me, f, i) = (c.clone(), self.clone(), self.filter.clone(), self.index);
            let bt = ui::pill_tag(&format!("{}    {}\n{detail}", iptv::clock(ps), s(&p, "t")), live.then_some("active"), move || {
                if live {
                    app().play_live(f.clone(), i);
                } else if future {
                    let on = iptv::toggle_reminder(&s(&c2, "k"), &s(&c2, "n"), &s(&p, "t"), ps, false);
                    app().toast(&if on {
                        format!("Sẽ nhắc lúc {} (5 phút trước giờ phát, khi app đang mở).", iptv::clock((ps - 300.0).max(iptv::now_sec())))
                    } else {
                        "Đã bỏ nhắc.".into()
                    });
                    me.build();
                }
            });
            if let Some(l) = bt.child().and_then(|x| x.downcast::<gtk::Label>().ok()) {
                l.set_xalign(0.0);
            }
            bt.set_halign(gtk::Align::Fill);
            if live {
                current = Some(bt.clone().upcast());
            }
            b.add(&bt);
        }
        if let Some(w) = current {
            ui::after(60, move || keynav::focus_and_show(&w));
        }
    }
}

impl Page for GuidePage {
    fn base(&self) -> &PageBase {
        &self.base
    }

    fn start(self: Rc<Self>) {
        self.base.loading("Đang tải…");
        let (f, i) = (self.filter.clone(), self.index);
        let me = self.clone();
        ui::spawn(async move { iptv::at(&f, i).await }, move |c| {
            *me.ch.borrow_mut() = c;
            me.build();
        });
    }
}

// ---- Cài đặt Truyền hình ----

pub struct TvSettingsPage {
    base: PageBase,
    epg: gtk::Entry,
}

pub fn settings() -> Rc<dyn Page> {
    let epg = ui::entry();
    epg.set_width_chars(48);
    epg.set_placeholder_text(Some("http://…/epg.xml.gz (để trống = lấy từ danh sách)"));
    let p = Rc::new(TvSettingsPage { base: PageBase::new("tv"), epg });
    p.base.keep(&p.epg);
    p
}

impl TvSettingsPage {
    fn build(self: &Rc<Self>) {
        let b = &self.base;
        b.clear();
        b.add(&ui::header("Truyền hình — Cài đặt"));
        b.add(&ui::label("Danh sách kênh", &["h2"], false));
        let active = iptv::active_list().map(|l| l.id).unwrap_or_default();
        for l in iptv::lists() {
            let detail = match (&l.err, l.updated) {
                (Some(e), _) => format!("Lỗi: {e}"),
                (None, 0) => "Chưa tải".into(),
                _ => format!("{} kênh · cập nhật {}", l.count, iptv::clock(l.updated as f64 / 1000.0)),
            };
            let from = l.url.clone().unwrap_or_else(|| format!("tệp «{}»", l.src.clone().unwrap_or_default()));
            let id = l.id.clone();
            let me = self.clone();
            let use_btn = ui::pill_tag(&format!("{}{}", if l.id == active { "✓  " } else { "" }, l.name), (l.id == active).then_some("active"), move || {
                iptv::set_active(Some(&id));
                refresh_list(false);
                me.build();
            });
            use_btn.set_size_request(px(260.0), -1);
            let id = l.id.clone();
            let me = self.clone();
            let reload = ui::pill("Tải lại", move || {
                iptv::set_active(Some(&id));
                app().toast("Đang tải lại danh sách…");
                let me = me.clone();
                ui::spawn(async { iptv::refresh(true).await }, move |r| {
                    app().toast(&match r {
                        Ok(()) => "Đã tải lại danh sách.".into(),
                        Err(e) => cbtv::util::friendly(&e),
                    });
                    me.build();
                });
            });
            let (id, nm) = (l.id.clone(), l.name.clone());
            let me = self.clone();
            let rename = ui::pill("Đổi tên", move || {
                let (id, nm, me) = (id.clone(), nm.clone(), me.clone());
                ui::local(async move {
                    let e = ui::entry();
                    e.set_text(&nm);
                    e.set_max_length(40);
                    e.connect_activate(|_| app().close_dialog(0));
                    if app().ask_async("Đổi tên danh sách", "", &["Lưu", "Huỷ"], Some(e.clone().upcast()), 0).await == 0 {
                        iptv::rename_list(&id, e.text().trim());
                    }
                    me.build();
                });
            });
            let (id, nm) = (l.id.clone(), l.name.clone());
            let me = self.clone();
            let remove = ui::pill("Xoá", move || {
                let (id, nm, me) = (id.clone(), nm.clone(), me.clone());
                ui::local(async move {
                    if app().confirm(&format!("Xoá danh sách «{nm}»?"), "", "Xoá", "Huỷ").await {
                        iptv::remove_list(&id);
                        me.build();
                    }
                });
            });
            b.add(&ui::row(&[use_btn.upcast(), reload.upcast(), rename.upcast(), remove.upcast(), ui::dim(&format!("{detail} · {from}")).upcast()]));
        }
        let me = self.clone();
        b.add(&ui::row(&[ui::pill("+  Thêm danh sách (địa chỉ / tệp M3U)", move || {
            let m = me.clone();
            ask_add(Rc::new(move || m.build()))
        })
        .upcast()]));
        b.add(&ui::dim("App không kèm sẵn kênh. Thêm danh sách M3U / M3U8 mà bạn có quyền xem; app đọc nhóm, logo, đài radio và địa chỉ lịch phát sóng ghi trong danh sách. Danh sách theo địa chỉ tự tải lại khi cũ; danh sách từ tệp thì thêm lại khi có tệp mới."));

        b.add(&ui::label("Lịch phát sóng", &["h2"], false));
        self.epg.set_text(&iptv::epg_override().unwrap_or_default());
        b.add(&ui::dim(&format!("Địa chỉ EPG (XMLTV — .xml / .xml.gz). Để trống = lấy từ danh sách: {}",
            iptv::active_list().and_then(|l| l.epg).unwrap_or_else(|| "danh sách không ghi".into()))));
        let me = self.clone();
        let me2 = self.clone();
        b.add(&ui::row(&[
            self.epg.clone().upcast(),
            ui::pill("Lưu", move || {
                iptv::set_epg_override(Some(me.epg.text().trim()));
                me.reload_guide();
            })
            .upcast(),
            ui::pill("Tải lại lịch ngay", move || me2.reload_guide()).upcast(),
        ]));
        let g = iptv::guide();
        b.add(&ui::dim(&match g {
            Some(g) => format!("{} kênh có lịch · tải lúc {}", g.prog.len(), iptv::clock(g.fetched as f64 / 1000.0)),
            None => "Chưa tải lịch.".into(),
        }));

        b.add(&ui::label("Phát", &["h2"], false));
        let me = self.clone();
        let me2 = self.clone();
        b.add(&ui::row(&[
            ui::pill(&format!("Ẩn kênh máy không phát được: {}", if iptv::hide_bad() { "Bật" } else { "Tắt" }), move || {
                cbtv::prefs::set("iptv_hide_bad", Some(!iptv::hide_bad()));
                me.build();
            })
            .upcast(),
            ui::pill(&format!("Nguồn lỗi thì tự sang nguồn khác: {}", if iptv::auto_source() { "Bật" } else { "Tắt" }), move || {
                cbtv::prefs::set("iptv_auto_source", Some(!iptv::auto_source()));
                me2.build();
            })
            .upcast(),
            ui::pill("Xoá dấu «không phát được»", || {
                iptv::clear_bad();
                app().toast("Đã xoá — lần mở sau app thử lại các kênh đó.");
            })
            .upcast(),
        ]));
        b.add(&ui::dim("Danh sách có nhiều nguồn cho một kênh thì nguồn lỗi tự sang nguồn sau. Luồng phát đi thẳng tới máy chủ của kênh (kèm Referer / User-Agent danh sách ghi)."));
    }

    fn reload_guide(self: &Rc<Self>) {
        app().toast("Đang tải lịch phát sóng…");
        let me = self.clone();
        ui::spawn(async { iptv::refresh_guide(true).await }, move |r| {
            app().toast(&match r {
                Ok(()) => format!("Đã tải lịch: {} kênh có lịch.", iptv::guide().map(|g| g.prog.len()).unwrap_or(0)),
                Err(e) => cbtv::util::friendly(&e),
            });
            me.build();
        });
    }
}

impl Page for TvSettingsPage {
    fn base(&self) -> &PageBase {
        &self.base
    }

    fn start(self: Rc<Self>) {
        self.build();
    }

    fn has_input(&self) -> bool {
        true
    }
}
