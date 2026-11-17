//! Đổi trang phim: danh sách trang, đo nhanh, thêm / xoá, thêm lại trang mẫu. Bản Windows: SettingsPages.cs SitesPage.

use super::{Page, PageBase};
use crate::app::app;
use crate::css::px;
use crate::keynav;
use crate::ui;
use cbtv::prefs;
use gtk::prelude::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

pub struct SitesPage {
    base: PageBase,
    checks: RefCell<HashMap<String, String>>,
    /// Ô thêm trang nhiều dòng (dán một lần nhiều trang, mỗi dòng một trang); giữ riêng bộ đệm chữ như ô dán danh sách kênh
    /// (tv.rs ask_add). Ô nằm trong khung cuộn `add_box` — khung này được giữ qua các lần dựng lại trang.
    add_buf: gtk::TextBuffer,
    add_box: gtk::ScrolledWindow,
}

pub fn new() -> Rc<dyn Page> {
    let add_buf = gtk::TextBuffer::new(None::<&gtk::TextTagTable>);
    let view = gtk::TextView::with_buffer(&add_buf);
    view.set_wrap_mode(gtk::WrapMode::None);
    view.set_accepts_tab(false);
    view.set_left_margin(8);
    view.set_top_margin(6);
    view.set_bottom_margin(6);
    let add_box = gtk::ScrolledWindow::new(None::<&gtk::Adjustment>, None::<&gtk::Adjustment>);
    add_box.set_policy(gtk::PolicyType::Automatic, gtk::PolicyType::Automatic);
    add_box.set_size_request(px(440.0), px(84.0));
    add_box.add(&view);
    add_box.style_context().add_class("frame");
    let p = Rc::new(SitesPage { base: PageBase::new("sites"), checks: RefCell::new(HashMap::new()), add_buf, add_box });
    p.base.keep(&p.add_box);
    // Enter xuống dòng; Ctrl+Enter = «Thêm»
    let weak = Rc::downgrade(&p);
    view.connect_key_press_event(move |_, ev| {
        use gdk::keys::constants as k;
        let key = ev.keyval();
        if (key == k::Return || key == k::KP_Enter) && ev.state().contains(gdk::ModifierType::CONTROL_MASK) {
            if let Some(p) = weak.upgrade() {
                p.add_site();
            }
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    p
}

impl SitesPage {
    fn build(self: &Rc<Self>) {
        let focused = app().window.focused_widget().and_then(|w| w.downcast::<gtk::Button>().ok()).and_then(|b| b.label()).map(|s| s.to_string());
        let b = &self.base;
        b.clear();
        b.add(&ui::header("Đổi trang phim"));
        let n = ui::dim("Trang đang dùng có màu xanh. Trang chậm / không vào được (nhà mạng chặn, đổi tên miền): bấm «Đo» rồi chọn trang khác.");
        n.set_margin_bottom(px(16.0));
        b.add(&n);
        let cur = prefs::base_url();
        for s in prefs::sites() {
            let row = ui::hbox(10.0);
            row.set_margin_bottom(px(10.0));
            let host = cbtv::site::host_of(&s).unwrap_or_else(|| s.clone());
            let name = format!("{}{}", if s == cur { "●  " } else { "" }, cbtv::site::display_name(&host));
            let s1 = s.clone();
            let p = ui::pill_tag(&name, (s == cur).then_some("active"), move || use_site(&s1));
            p.set_size_request(px(260.0), -1);
            row.pack_start(&p, false, false, 0);
            let (me, s2) = (self.clone(), s.clone());
            row.pack_start(&ui::pill("Đo", move || me.check(&s2)), false, false, 0);
            let (me, s3, h3) = (self.clone(), s.clone(), host.clone());
            row.pack_start(
                &ui::pill("Xoá", move || {
                    let (me, s3, h3) = (me.clone(), s3.clone(), h3.clone());
                    ui::local(async move {
                        if !app().confirm(&format!("Xoá {h3} khỏi danh sách?"), "", "Xoá", "Huỷ").await {
                            return;
                        }
                        if !prefs::remove_site(&s3) {
                            app().toast("Phải còn ít nhất một trang.");
                        }
                        app().rebuild_menu();
                        me.build();
                    });
                }),
                false,
                false,
                0,
            );
            if let Some(r) = self.checks.borrow().get(&s) {
                let t = ui::dim(r);
                t.set_valign(gtk::Align::Center);
                row.pack_start(&t, false, false, 0);
            }
            b.add(&row);
        }
        let me = self.clone();
        b.add(&ui::row(&[ui::pill("Đo tất cả", move || {
            for s in prefs::sites() {
                me.check(&s);
            }
        })
        .upcast()]));

        let h = ui::header("Thêm trang");
        h.set_margin_top(px(22.0));
        b.add(&h);
        let hint = ui::dim(prefs::ADD_SITES_HINT);
        hint.set_margin_bottom(px(6.0));
        b.add(&hint);
        let add = ui::hbox(10.0);
        add.set_margin_bottom(px(10.0));
        if let Some(p) = self.add_box.parent() {
            if let Ok(c) = p.downcast::<gtk::Container>() {
                c.remove(&self.add_box);
            }
        }
        add.pack_start(&self.add_box, false, false, 0);
        let me = self.clone();
        let btn = ui::pill("Thêm", move || me.add_site());
        btn.set_valign(gtk::Align::Start);
        add.pack_start(&btn, false, false, 0);
        b.add(&add);
        let n = ui::dim(
            "Ctrl+Enter = Thêm. App đọc được trang kiểu yanhh3d, theme HaLim (hoathinh3d…), kiểu PhimMoi (phimmois.fun), \
             mephim.ddns.net, KKPhim (kkphim.com), NguonC (phim.nguonc.com), VSMOV (vsmov.com) và CLB Phim Xưa (sc.k-20.xyz).",
        );
        n.set_margin_bottom(px(10.0));
        b.add(&n);
        let missing = prefs::missing_presets();
        if !missing.is_empty() {
            let l = ui::dim("Thêm lại trang mẫu:");
            ui::margins(&l, 8.0, 0.0, 8.0, 0.0);
            b.add(&l);
            let row = ui::flow(10.0, 10.0);
            for m in missing {
                let me = self.clone();
                let m2 = m.clone();
                let p = ui::pill(&format!("+ {}", cbtv::site::host_of(&m).unwrap_or_default()), move || {
                    prefs::add_site(&m2);
                    me.build();
                });
                ui::add_flow(&row, p.upcast_ref());
            }
            b.add(&row);
        }
        if let Some(text) = focused {
            let body = b.body.clone();
            ui::after(30, move || {
                if let Some(w) = keynav::targets(body.upcast_ref())
                    .into_iter()
                    .find(|w| w.clone().downcast::<gtk::Button>().ok().and_then(|b| b.label()).map(|l| l == text.as_str()).unwrap_or(false))
                {
                    w.grab_focus();
                }
            });
        }
    }

    /// «Thêm»: một trang mới → như trước (thêm, đo nhanh); nhiều trang → chỉ thêm cả loạt (không đổi trang đang dùng) và báo
    /// «Đã thêm N trang: …». Không có trang mới → báo, giữ chữ trong ô để sửa.
    fn add_site(self: &Rc<Self>) {
        let buf = &self.add_buf;
        let text = buf.text(&buf.start_iter(), &buf.end_iter(), false).map(|t| t.to_string()).unwrap_or_default();
        let r = prefs::add_sites(&text);
        if r.added.is_empty() {
            app().toast(r.none_text());
            return;
        }
        buf.set_text("");
        if r.added.len() > 1 || r.existing > 0 || r.invalid > 0 {
            app().toast(&r.added_text());
        }
        self.build();
        for u in &r.added {
            self.check(u);
        }
    }

    fn check(self: &Rc<Self>, s: &str) {
        self.checks.borrow_mut().insert(s.to_string(), "đang đo…".into());
        self.build();
        let me = self.clone();
        let s2 = s.to_string();
        ui::spawn(
            {
                let s = s2.clone();
                async move { cbtv::util::with_timeout(25.0, cbtv::site::check(&s)).await }
            },
            move |r| {
                let text = match r {
                    Ok(c) if c.films > 0 => format!("{} ms · {} phim", c.ms, c.films),
                    Ok(c) => format!("{} ms · không thấy phim (bị chặn / đổi giao diện?)", c.ms),
                    Err(e) => format!("lỗi: {}", cbtv::util::friendly(&e)),
                };
                me.checks.borrow_mut().insert(s2, text);
                me.build();
            },
        );
    }
}

fn use_site(s: &str) {
    let a = app();
    if s == prefs::base_url() {
        a.show_root(crate::menu::home_page());
        return;
    }
    prefs::set_base_url(s);
    a.set_categories(Vec::new());
    a.show_root(crate::menu::home_page());
    a.toast(&format!("Đã đổi sang {}.", cbtv::site::host_of(s).unwrap_or_default()));
}

impl Page for SitesPage {
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
