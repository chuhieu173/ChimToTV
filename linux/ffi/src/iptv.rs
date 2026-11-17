//! Truyền hình (IPTV) cho app WPF — lệnh `iptv.*` gọi lõi `cbtv::iptv` (danh sách M3U, lịch XMLTV, lọc / trang kênh,
//! yêu thích, kênh vừa xem, kênh hỏng, nhắc giờ phát). Bản Linux gọi thẳng lõi.

use crate::Res;
use cbtv::iptv;
use serde_json::{json, Value};

fn s(a: &Value, k: &str) -> String {
    a.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string()
}

fn opt_s(a: &Value, k: &str) -> Option<String> {
    a.get(k).and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(|s| s.to_string())
}

fn b(a: &Value, k: &str) -> bool {
    a.get(k).and_then(|v| v.as_bool()).unwrap_or(false)
}

fn n(a: &Value, k: &str) -> i64 {
    a.get(k).and_then(|v| v.as_i64()).unwrap_or(0)
}

fn filter(a: &Value) -> iptv::Filter {
    a.get("filter").and_then(|f| serde_json::from_value(f.clone()).ok()).unwrap_or_default()
}

fn err(e: cbtv::Error) -> String {
    cbtv::util::friendly(&e)
}

pub fn sync(m: &str, a: &Value) -> Option<Res> {
    Some(match m {
        "iptv.lists" => Ok(json!({ "lists": iptv::lists(), "active": iptv::active_list().map(|l| l.id) })),
        "iptv.status" => Ok(iptv::status()),
        "iptv.add" => Ok(json!(iptv::add_list(&s(a, "url"), opt_s(a, "name").as_deref()))),
        "iptv.addMany" => Ok(json!(iptv::add_lists(&s(a, "text"), opt_s(a, "name").as_deref()))),
        "iptv.addFile" => iptv::add_file(&s(a, "path"), opt_s(a, "name").as_deref()).map(|l| json!(l)).map_err(err),
        "iptv.setActive" => {
            iptv::set_active(opt_s(a, "id").as_deref());
            Ok(Value::Null)
        }
        "iptv.rename" => {
            iptv::rename_list(&s(a, "id"), &s(a, "name"));
            Ok(Value::Null)
        }
        "iptv.remove" => {
            iptv::remove_list(&s(a, "id"));
            Ok(Value::Null)
        }
        "iptv.epg" => Ok(json!({ "override": iptv::epg_override(), "url": iptv::epg_url(),
            "fetched": iptv::guide().map(|g| g.fetched), "channels": iptv::guide().map(|g| g.prog.len()) })),
        "iptv.setEpg" => {
            iptv::set_epg_override(opt_s(a, "url").as_deref());
            Ok(Value::Null)
        }
        "iptv.setFavorite" => {
            iptv::set_favorite(&s(a, "key"), b(a, "on"));
            Ok(Value::Null)
        }
        "iptv.recent" => Ok(json!(iptv::recent())),
        // Các hàng Truyền hình của trang chủ, không đọc tệp (dựng ngay); "loaded": false thì gọi iptv.homeRows rồi dựng lại
        "iptv.homeRowsNow" => Ok(iptv::home_rows_now(n(a, "limit").clamp(1, 60) as usize)),
        "iptv.markBad" => {
            iptv::mark_bad(&s(a, "url"), &s(a, "reason"));
            Ok(Value::Null)
        }
        "iptv.badReason" => Ok(json!(iptv::bad_reason(&s(a, "url")))),
        "iptv.clearBad" => {
            iptv::clear_bad();
            Ok(Value::Null)
        }
        "iptv.clearBadFor" => {
            iptv::clear_bad_for(&s(a, "key"));
            Ok(Value::Null)
        }
        "iptv.settings" => Ok(json!({ "hideBad": iptv::hide_bad(), "autoSource": iptv::auto_source() })),
        "iptv.toggleReminder" => Ok(json!(iptv::toggle_reminder(
            &s(a, "key"),
            &s(a, "name"),
            &s(a, "title"),
            a.get("s").and_then(|v| v.as_f64()).unwrap_or(0.0),
            b(a, "kick")
        ))),
        "iptv.hasReminder" => Ok(json!(iptv::has_reminder(&s(a, "key"), a.get("s").and_then(|v| v.as_f64()), b(a, "kick")))),
        "iptv.dueReminder" => Ok(iptv::due_reminder().unwrap_or(Value::Null)),
        "iptv.isPlaceholder" => Ok(json!(iptv::is_placeholder(&s(a, "url")))),
        "iptv.kickText" => Ok(json!(iptv::kick_text(a.get("kick").and_then(|v| v.as_f64()).unwrap_or(0.0), iptv::now_sec()))),
        _ => return None,
    })
}

pub async fn call(m: &str, a: &Value) -> Option<Res> {
    Some(match m {
        // Tải danh sách đang chọn (force: bỏ qua bản còn mới) rồi lịch nếu cũ
        "iptv.refresh" => iptv::refresh(b(a, "force")).await.map(|_| Value::Null).map_err(err),
        "iptv.autoRefresh" => {
            iptv::auto_refresh().await;
            Ok(Value::Null)
        }
        // Trình phát: danh sách cũ hơn `seconds` thì tải lại (link có hạn dùng / trận chưa có link)
        "iptv.refreshIfOlder" => iptv::refresh_if_older_than(n(a, "seconds")).await.map(|_| Value::Null).map_err(err),
        "iptv.refreshGuide" => iptv::refresh_guide(b(a, "force")).await.map(|_| Value::Null).map_err(err),
        "iptv.groups" => Ok(iptv::groups().await),
        "iptv.homeRows" => Ok(iptv::home_rows(n(a, "limit").clamp(1, 60) as usize).await),
        "iptv.page" => Ok(iptv::page(&filter(a), n(a, "offset").max(0) as usize, n(a, "limit").clamp(1, 500) as usize).await),
        "iptv.at" => Ok(iptv::at(&filter(a), n(a, "index").max(0) as usize).await),
        "iptv.indexOf" => Ok(json!(iptv::index_of(&filter(a), opt_s(a, "key").as_deref(), opt_s(a, "num").as_deref()).await)),
        "iptv.checkPlaceholder" => Ok(json!(
            iptv::check_placeholder(&s(a, "url"), opt_s(a, "referer").as_deref(), opt_s(a, "ua").as_deref()).await
        )),
        "iptv.played" => {
            iptv::played(&s(a, "key")).await;
            Ok(Value::Null)
        }
        _ => return None,
    })
}
