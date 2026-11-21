//! Thêm nhiều trang phim một lần (dán nhiều dòng) — cùng ca với SitesTests.cs (Windows). Kho cài đặt là một cho cả tiến trình →
//! test chạy lần lượt (khoá LOCK), mỗi test một thư mục dữ liệu riêng. Chỉ dùng tên miền bịa (*.example).

use cbtv::prefs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard};

static LOCK: Mutex<()> = Mutex::new(());
static N: AtomicUsize = AtomicUsize::new(0);

struct Fresh {
    dir: PathBuf,
    _g: MutexGuard<'static, ()>,
}

impl Drop for Fresh {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn fresh() -> Fresh {
    let g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let dir = std::env::temp_dir().join(format!("cbtv-sites-{}-{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
    let _ = std::fs::remove_dir_all(&dir);
    prefs::load(Some(dir.clone()));
    Fresh { dir, _g: g }
}

#[test]
fn add_many_sites_keeps_current_site_and_skips_existing() {
    let _f = fresh();
    prefs::set_sites(vec!["https://phim-a.example".into(), "https://www.phim-b.example/xem".into()]);
    prefs::set_base_url("https://phim-a.example");
    let r = prefs::add_sites(
        "phim-c.example\n\
         http://www.phim-a.example/\n\
         https://phim-d.example/tap-1?sv=2   PHIM-B.example\n\
         phim-c.example\n\
         bad..host\n",
    );
    assert_eq!(r.added, vec!["https://phim-c.example", "https://phim-d.example"]);
    assert_eq!(r.existing, 2);
    assert_eq!(r.invalid, 1);
    assert_eq!(
        prefs::sites(),
        vec!["https://phim-a.example", "https://www.phim-b.example/xem", "https://phim-c.example", "https://phim-d.example"]
    );
    // Không đổi trang đang dùng
    assert_eq!(prefs::base_url(), "https://phim-a.example");
}

#[test]
fn nothing_new_changes_nothing() {
    let _f = fresh();
    prefs::set_sites(vec!["https://phim-a.example".into()]);
    let before = prefs::sites();
    let r = prefs::add_sites("www.phim-a.example\n# phim-z.example\nchữ không phải trang");
    assert!(r.added.is_empty());
    assert_eq!((r.existing, r.invalid), (1, 0));
    assert_eq!(prefs::sites(), before);
    let r = prefs::add_sites("bad..host");
    assert_eq!(r, prefs::AddSites { added: vec![], existing: 0, invalid: 1 });
    assert_eq!(prefs::sites(), before);
}

#[test]
fn single_site_is_added_at_the_end() {
    let _f = fresh();
    let presets = prefs::sites();
    let r = prefs::add_sites("  phim-moi.example/  ");
    assert_eq!(r.added, vec!["https://phim-moi.example"]);
    let mut want = presets;
    want.push("https://phim-moi.example".into());
    assert_eq!(prefs::sites(), want);
}
