//! Trang chủ. Kiểu theo trang: Xem tiếp, phim theo dõi có tập mới, rồi các nhóm phim của trang đang dùng. Kiểu tổng hợp
//! (mặc định): phim từ mọi nguồn, gộp phim trùng, xếp hàng theo lịch sử xem (home_mix.rs). Bản Windows: Pages.cs HomePage.

use super::home_tv;
use super::lists::film_card;
use super::{Page, PageBase};
use crate::app::app;
use crate::card::{card, CardOpts};
use crate::keynav;
use crate::ui;
use cbtv::home_feed as hf;
use cbtv::{iptv, prefs, Film, Home};
use serde_json::Value;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

pub struct HomePage {
    base: PageBase,
    home: RefCell<Option<Home>>,
    site: RefCell<String>,
    mix: std::cell::Cell<bool>,
    kids: std::cell::Cell<bool>,
    rows: RefCell<String>,
    /// Dữ liệu các hàng Truyền hình lần dựng gần nhất (iptv::home_rows_now / home_rows).
    tv: RefCell<Value>,
    tv_loading: Cell<bool>,
    /// Các hàng Truyền hình đang hiện theo thứ tự: loại hàng, tên ô đầu.
    shown: RefCell<Vec<(String, Option<String>)>>,
}

pub fn new() -> Rc<dyn Page> {
    if prefs::home_mix_on() {
        return super::home_mix::new();
    }
    new_site()
}

/// Trang chủ kiểu theo trang đang dùng.
pub fn new_site() -> Rc<dyn Page> {
    Rc::new(HomePage {
        base: PageBase::new("home"),
        home: RefCell::new(None),
        site: RefCell::new(String::new()),
        mix: std::cell::Cell::new(false),
        kids: std::cell::Cell::new(false),
        rows: RefCell::new(String::new()),
        tv: RefCell::new(Value::Null),
        tv_loading: Cell::new(false),
        shown: RefCell::new(Vec::new()),
    })
}

impl HomePage {
    fn build(self: &Rc<Self>) {
        let Some(home) = self.home.borrow().clone() else { return };
        let b = &self.base;
        b.clear();
        let on = crate::hooks::rows_on();
        let history: Vec<_> = if on.contains("continue") { prefs::history().into_iter().take(12).collect() } else { Vec::new() };
        if !history.is_empty() {
            let cards = history
                .iter()
                .map(|h| {
                    let (fu, eu) = (h.film_url.clone(), h.ep_url.clone());
                    card(
                        Film::new(h.film_url.clone(), h.title.clone(), h.poster.clone(), None),
                        Rc::new(move || app().play(&fu, &eu, true)),
                        CardOpts { sub: Some(h.ep_title.clone()), ..Default::default() },
                    )
                })
                .collect();
            b.add(&ui::section("Xem tiếp", Some("Enter: xem tiếp ngay"), cards));
        }
        let fresh: Vec<_> = if on.contains("new-eps") { prefs::follows().into_iter().filter(|f| f.new_count() > 0).collect() } else { Vec::new() };
        if !fresh.is_empty() {
            let cards = fresh
                .iter()
                .map(|f| {
                    let film = Film::new(f.film_url.clone(), f.title.clone(), f.poster.clone(), cbtv::util::non_empty(Some(&f.latest)));
                    let ff = film.clone();
                    card(film, Rc::new(move || super::detail::open_film(&ff)), CardOpts { fresh: Some(format!("+{}", f.new_count())), ..Default::default() })
                })
                .collect();
            b.add(&ui::section("Phim theo dõi có tập mới", None, cards));
        }
        // Hàng Truyền hình (kiểu theo trang: ngay dưới Xem tiếp, theo thứ tự trong cài đặt)
        *self.tv.borrow_mut() = iptv::home_rows_now(home_tv::TV_MAX);
        let mut shown = Vec::new();
        for (slot, title, items) in home_tv::rows_to_show(&self.tv.borrow(), &hf::row_prefs(), self.kids.get()) {
            let (me, sl) = (self.clone(), slot.clone());
            let menu: Rc<dyn Fn()> = Rc::new(move || me.row_menu(&sl));
            let (cards, more, first) = home_tv::cards(&slot, &items, menu.clone());
            b.add(&home_tv::strip(title, cards, more, menu));
            shown.push((slot, first));
        }
        *self.shown.borrow_mut() = shown;
        self.maybe_load_tv();
        for s in &home.sections {
            b.add(&ui::section(&s.title, None, s.films.iter().map(film_card).collect()));
        }
        if home.sections.is_empty() {
            let t = ui::label("Trang không có phim nào", &["big"], true);
            t.set_margin_top(crate::css::px(30.0));
            b.add(&t);
            b.add(&ui::dim("Có thể trang đã đổi giao diện, hoặc nhà mạng chặn trang này (trang chặn không có phim). Thử trang khác:"));
            b.add(&ui::row(&[ui::pill("🌐  Đổi trang phim", || app().show_root(super::sites::new())).upcast()]));
        }
    }

    /// Danh sách kênh chưa đọc (vừa mở app): đọc ở nền rồi dựng lại để hiện các hàng Truyền hình (giữ ô đang chọn).
    fn maybe_load_tv(self: &Rc<Self>) {
        if self.tv_loading.get() || self.tv.borrow()["loaded"].as_bool().unwrap_or(false) || iptv::active_list().is_none() {
            return;
        }
        self.tv_loading.set(true);
        let me = self.clone();
        ui::spawn(async { iptv::home_rows(home_tv::TV_MAX).await }, move |v| {
            me.tv_loading.set(false);
            if !v["loaded"].as_bool().unwrap_or(false) || !me.base.body.is_mapped() || me.home.borrow().is_none() {
                return;
            }
            let focus = app().window.focused_widget().filter(|f| f.is_ancestor(&me.base.body)).map(|f| f.widget_name().to_string());
            me.build();
            if let Some(name) = focus.filter(|n| !n.is_empty()) {
                me.focus_name(name);
            }
        });
    }

    fn focus_name(&self, name: String) {
        let body = self.base.body.clone();
        ui::after(40, move || {
            if let Some(w) = keynav::find_named(body.upcast_ref(), &name) {
                keynav::focus_and_show(&w);
            }
        });
    }

    /// Sửa nhanh một hàng Truyền hình: ẩn, ▲ / ▼ (qua hàng Truyền hình kề nó — kiểu theo trang chỉ có các hàng này), «Các
    /// hàng…». Hồ sơ trẻ em: hỏi mã PIN phụ huynh trước (nếu đã đặt).
    fn row_menu(self: &Rc<Self>, slot: &str) {
        let me = self.clone();
        let slot = slot.to_string();
        ui::local(async move {
            let a = app();
            if prefs::kids() && prefs::has_parent_pin() && !a.check_parent("Nhập mã PIN phụ huynh để sửa trang chủ.").await {
                return;
            }
            let Some(title) = hf::tv_row_title(&slot) else { return };
            let on_page = me.shown.borrow().clone();
            let shown: Vec<String> = on_page.iter().map(|x| x.0.clone()).collect();
            let p = hf::row_prefs();
            let at = on_page.iter().position(|x| x.0 == slot);
            let next_focus = at.and_then(|i| on_page.get(i + 1).or(if i > 0 { on_page.get(i - 1) } else { None })).and_then(|x| x.1.clone());
            let up = hf::move_shown(&p, &shown, &slot, true);
            let down = hf::move_shown(&p, &shown, &slot, false);
            let mut labels = vec!["Ẩn hàng này"];
            if up.is_some() {
                labels.push("▲  Chuyển lên");
            }
            if down.is_some() {
                labels.push("▼  Chuyển xuống");
            }
            labels.push("☰  Các hàng…");
            labels.push("Huỷ");
            let focus = a.window.focused_widget().map(|w| w.widget_name().to_string());
            let i = a.ask_async(&format!("Hàng «{title}»"), "", &labels, None, 0).await;
            if i < 0 {
                return;
            }
            match labels[i as usize] {
                "Ẩn hàng này" => {
                    me.apply(hf::hide(&p, &slot), next_focus.or(focus));
                    a.toast(&format!("Đã ẩn hàng «{title}» — bật lại trong Cài đặt → Các hàng trên trang chủ."));
                }
                "▲  Chuyển lên" => me.apply(up.unwrap_or_default(), focus),
                "▼  Chuyển xuống" => me.apply(down.unwrap_or_default(), focus),
                "☰  Các hàng…" => a.push(super::home_rows::rows()),
                _ => {}
            }
        });
    }

    /// Lưu cài đặt các hàng rồi dựng lại (không tải lại trang).
    fn apply(self: &Rc<Self>, p: Vec<(String, bool)>, focus: Option<String>) {
        hf::save_rows(&p);
        *self.rows.borrow_mut() = crate::hooks::rows_signature();
        self.build();
        match focus {
            Some(f) => self.focus_name(f),
            None => {
                let me = self.clone();
                ui::after(40, move || super::focus_first(me.as_ref()));
            }
        }
    }
}

use gtk::prelude::*;

impl Page for HomePage {
    fn base(&self) -> &PageBase {
        &self.base
    }

    fn start(self: Rc<Self>) {
        self.mix.set(prefs::home_mix_on());
        self.kids.set(prefs::kids());
        *self.rows.borrow_mut() = crate::hooks::rows_signature();
        let base = prefs::base_url();
        *self.site.borrow_mut() = base.clone();
        self.base.loading(&format!("Đang tải {}…", cbtv::site::host_of(&base).unwrap_or_default()));
        let t = self.base.next_token();
        let me = self.clone();
        let b2 = base.clone();
        ui::spawn(async move { cbtv::site::home_of(Some(&b2)).await }, move |r| {
            if t != me.base.token() {
                return;
            }
            match r {
                Ok(home) => {
                    if let Some(m) = home.moved_to.as_deref().and_then(prefs::normalize_url) {
                        if m != base {
                            prefs::replace_site(&base, &m);
                            app().toast(&format!("Trang đã chuyển sang {} — app đã đổi theo.", cbtv::site::host_of(&m).unwrap_or_default()));
                            *me.site.borrow_mut() = m;
                        }
                    }
                    app().set_categories(home.categories.clone());
                    *me.home.borrow_mut() = Some(home);
                    me.build();
                }
                Err(e) => {
                    let m2 = me.clone();
                    me.base.show_error(&cbtv::util::friendly(&e), Rc::new(move || m2.clone().start()));
                }
            }
        });
    }

    fn returned(self: Rc<Self>) {
        // Đổi kiểu trang chủ / hồ sơ trẻ em / trang phim trong Cài đặt → tải lại
        if prefs::home_mix_on() != self.mix.get() || prefs::kids() != self.kids.get() || prefs::base_url() != *self.site.borrow()
            || crate::hooks::rows_signature() != *self.rows.borrow()
        {
            if prefs::home_mix_on() {
                app().replace(super::home_mix::new());
                return;
            }
            self.start();
            return;
        }
        self.build();
    }
}
