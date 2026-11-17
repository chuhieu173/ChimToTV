//! Các hàng Truyền hình trên trang chủ (Kênh vừa xem, Kênh yêu thích, Trận đang / sắp đá, Radio): dựng tại chỗ từ danh sách
//! kênh (cbtv::iptv::home_rows_now / home_rows), không qua tải phim — bật / tắt / xếp thứ tự như các hàng phim
//! (cbtv::home_feed). Bấm thẻ = phát luôn; «Xem thêm» mở màn Truyền hình. Bản Windows: Pages.cs HomePage (TvStrip…).

use super::tv;
use crate::app::app;
use crate::css::px;
use crate::ui;
use cbtv::home_feed as hf;
use cbtv::iptv::Filter;
use gtk::prelude::*;
use serde_json::Value;
use std::rc::Rc;

/// Số kênh tối đa một hàng.
pub const TV_MAX: usize = 16;

fn s(v: &Value, k: &str) -> String {
    v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string()
}

/// Hàng Truyền hình đang bật của người xem (theo thứ tự cài đặt) có kênh: (loại hàng, tiêu đề, các ô kênh). Hồ sơ trẻ em:
/// không có «Trận đang / sắp đá», «Radio».
pub fn rows_to_show(tv: &Value, prefs: &[(String, bool)], kids: bool) -> Vec<(String, &'static str, Vec<Value>)> {
    prefs
        .iter()
        .filter(|p| p.1)
        .filter_map(|(id, _)| {
            let title = hf::tv_row_title(id)?;
            if kids && hf::ADULT_ROWS.contains(&id.as_str()) {
                return None;
            }
            let items = tv.get(id.strip_prefix("tv-")?)?.as_array().filter(|a| !a.is_empty())?;
            Some((id.clone(), title, items.clone()))
        })
        .collect()
}

/// Các ô của một hàng: thẻ kênh (bấm = phát luôn; phím Menu / M / Shift+F10 / chuột phải = `menu`, sửa nhanh hàng) + ô
/// «Xem thêm» cuối dải. Trả (các ô, việc «Xem thêm», tên ô đầu). Tên ô: "<hàng>:<danh sách>:<khoá kênh>" (giữ ô đang chọn
/// khi dựng lại).
pub fn cards(slot: &str, items: &[Value], menu: Rc<dyn Fn()>) -> (Vec<gtk::Widget>, Rc<dyn Fn()>, Option<String>) {
    let mut out: Vec<gtk::Widget> = Vec::new();
    for c in items {
        let b = tv::channel_card(c);
        b.set_widget_name(&format!("{slot}:{}:{}", s(c, "l"), s(c, "k")));
        b.set_hexpand(false); // tên kênh giãn ngang (hexpand) lan lên thẻ: thẻ chia nhau bề rộng dải, cách xa nhau

        let c1 = c.clone();
        b.connect_clicked(move |_| open_channel(&c1));
        let m = menu.clone();
        b.connect_button_release_event(move |_, ev| {
            if ev.button() == 3 {
                m();
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        let m = menu.clone();
        b.connect_key_press_event(move |_, ev| {
            use gdk::keys::constants as k;
            let key = ev.keyval();
            let shift = ev.state().contains(gdk::ModifierType::SHIFT_MASK);
            if key == k::Menu || key == k::m || key == k::M || (key == k::F10 && shift) {
                m();
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        out.push(b.upcast());
    }
    let first = out.first().map(|w| w.widget_name().to_string());
    // «Kênh yêu thích» → màn Truyền hình chọn sẵn Yêu thích; «Kênh vừa xem» → như mở từ menu; còn lại → tất cả kênh
    let start = match slot {
        "tv-favs" => Some(Filter { favs: true, ..Default::default() }),
        "tv-recent" => None,
        _ => Some(Filter::default()),
    };
    let more: Rc<dyn Fn()> = Rc::new(move || app().show_root(tv::with_filter(start.clone())));
    let m2 = more.clone();
    let tile = ui::more_tile(move || m2(), None);
    tile.set_size_request(px(112.0), px(118.0)); // cao bằng thẻ kênh
    tile.set_widget_name(&format!("more:{slot}"));
    out.push(tile.upcast());
    (out, more, first)
}

/// Một hàng vuốt ngang (trang chủ kiểu theo trang): tiêu đề (chuột phải = `menu`) + dải các ô.
pub fn strip(title: &str, cards: Vec<gtk::Widget>, more: Rc<dyn Fn()>, menu: Rc<dyn Fn()>) -> gtk::Box {
    let t = ui::label(title, &["h1"], false);
    let ev = gtk::EventBox::new();
    ev.add(&t);
    ev.connect_button_release_event(move |_, e| {
        if e.button() == 3 {
            menu();
        }
        glib::Propagation::Proceed
    });
    ui::strip(ev.upcast_ref(), cards, Some(more))
}

/// Bấm thẻ kênh: phát luôn (kênh của danh sách khác — «Kênh vừa xem» — thì đổi danh sách); trận còn hơn 30 phút mới đá thì
/// hỏi đặt nhắc như màn Truyền hình. Hết giờ xem: màn chặn như khi mở phim.
pub fn open_channel(c: &Value) {
    if let Some(bl) = crate::limits::blocked() {
        let c = c.clone();
        crate::limits::limit_reached_then(bl, Rc::new(move || open_channel(&c)));
        return;
    }
    let (k, l) = (s(c, "k"), s(c, "l"));
    if s(c, "match") != "later" {
        app().play_live_key(k, Some(l));
        return;
    }
    let c = c.clone();
    ui::local(async move {
        match tv::ask_not_started(&c).await {
            0 => tv::toggle_kick_reminder(&c),
            1 => app().play_live_key(k, Some(l)),
            _ => {}
        }
    });
}
