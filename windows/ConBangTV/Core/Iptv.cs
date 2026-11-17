using System.Text.Json.Nodes;

namespace ConBangTV.Core;

/// Bộ lọc của lưới / bảng kênh (như lõi cbtv::iptv::Filter): nhóm (số thứ tự; null = tất cả), chỉ yêu thích, chữ tìm.
public sealed record IptvFilter(int? Group = null, bool Favs = false, string Q = "");

/// <summary>
/// Truyền hình (IPTV) — danh sách kênh M3U người xem tự thêm, lịch XMLTV, kênh trận đấu: lõi Rust làm hết (lệnh iptv.* của
/// conbang_core.dll — cbtv::iptv), C# chỉ dựng giao diện. Kết quả là JSON (JsonNode) để khỏi khai báo lại từng kiểu.
/// </summary>
public static class Iptv
{
    public static JsonObject Status() => Native.SyncNode("iptv.status") as JsonObject ?? new JsonObject();

    /// Lần đổi dữ liệu (danh sách / lịch / yêu thích / dấu hỏng) — giao diện vẽ lại khi khác.
    public static long Version => Status()["version"]?.GetValue<long>() ?? 0;

    public static JsonArray Lists() => Native.SyncNode("iptv.lists")?["lists"] as JsonArray ?? new JsonArray();

    public static JsonObject? ActiveList() => Status()["active"] as JsonObject;

    public static JsonObject Add(string url, string? name) => (JsonObject)Native.SyncNode("iptv.add", new { url, name })!;

    /// Dán nhiều địa chỉ một lần (mỗi dòng một danh sách): { added: [danh sách…], existing: số địa chỉ đã có }.
    public static JsonObject AddMany(string text, string? name) => (JsonObject)Native.SyncNode("iptv.addMany", new { text, name })!;

    public static JsonObject AddFile(string path, string? name) => (JsonObject)Native.SyncNode("iptv.addFile", new { path, name })!;

    public static void SetActive(string? id) => Native.SyncVoid("iptv.setActive", new { id });

    public static void Rename(string id, string name) => Native.SyncVoid("iptv.rename", new { id, name });

    public static void Remove(string id) => Native.SyncVoid("iptv.remove", new { id });

    public static Task Refresh(bool force) => Native.CallVoid("iptv.refresh", new { force });

    public static Task AutoRefresh() => Native.CallVoid("iptv.autoRefresh");

    public static Task RefreshIfOlder(int seconds) => Native.CallVoid("iptv.refreshIfOlder", new { seconds });

    public static Task RefreshGuide(bool force) => Native.CallVoid("iptv.refreshGuide", new { force });

    public static JsonObject Epg() => Native.SyncNode("iptv.epg") as JsonObject ?? new JsonObject();

    public static void SetEpg(string? url) => Native.SyncVoid("iptv.setEpg", new { url });

    public static async Task<JsonObject> Groups() => await Native.CallNode("iptv.groups") as JsonObject ?? new JsonObject();

    public static async Task<JsonObject> Page(IptvFilter f, int offset, int limit) =>
        await Native.CallNode("iptv.page", new { filter = f, offset, limit }) as JsonObject ?? new JsonObject();

    /// Kênh ở vị trí index của bộ lọc, đủ nguồn (urls: [{url, referer, ua, bad}]) và lịch (programmes). null = hết danh sách.
    public static async Task<JsonObject?> At(IptvFilter f, int index) => await Native.CallNode("iptv.at", new { filter = f, index }) as JsonObject;

    public static async Task<int> IndexOf(IptvFilter f, string? key = null, string? num = null) =>
        (await Native.CallNode("iptv.indexOf", new { filter = f, key, num }))?.GetValue<int>() ?? -1;

    /// Luồng HLS là hình chờ ngắn có hồi kết (đọc danh sách phát qua lõi)?
    public static async Task<bool> CheckPlaceholder(string url, string? referer, string? ua) =>
        (await Native.CallNode("iptv.checkPlaceholder", new { url, referer, ua }))?.GetValue<bool>() ?? false;

    public static Task Played(string key) => Native.CallVoid("iptv.played", new { key });

    public static void SetFavorite(string key, bool on) => Native.SyncVoid("iptv.setFavorite", new { key, on });

    public static JsonArray Recent() => Native.SyncNode("iptv.recent") as JsonArray ?? new JsonArray();

    public static void MarkBad(string url, string reason) => Native.SyncVoid("iptv.markBad", new { url, reason });

    public static string? BadReason(string url) => Native.SyncNode("iptv.badReason", new { url })?.GetValue<string>();

    public static void ClearBad() => Native.SyncVoid("iptv.clearBad");

    public static void ClearBadFor(string key) => Native.SyncVoid("iptv.clearBadFor", new { key });

    public static bool IsPlaceholder(string url) => Native.SyncNode("iptv.isPlaceholder", new { url })?.GetValue<bool>() ?? false;

    public static string KickText(double kick) => Native.SyncNode("iptv.kickText", new { kick })?.GetValue<string>() ?? "";

    public static bool HideBad
    {
        get => Prefs.GetBool("iptv_hide_bad", true);
        set => Prefs.SetBool("iptv_hide_bad", value);
    }

    public static bool AutoSource
    {
        get => Prefs.GetBool("iptv_auto_source", true);
        set => Prefs.SetBool("iptv_auto_source", value);
    }

    /// Bật / tắt nhắc (kick = lúc bóng lăn; không thì 5 phút trước giờ phát s). true = vừa đặt.
    public static bool ToggleReminder(string key, string name, string title, double s, bool kick) =>
        Native.SyncNode("iptv.toggleReminder", new { key, name, title, s, kick })?.GetValue<bool>() ?? false;

    public static bool HasReminder(string key, double? s, bool kick) =>
        Native.SyncNode("iptv.hasReminder", new { key, s, kick })?.GetValue<bool>() ?? false;

    /// Nhắc đã tới giờ (lấy ra khỏi danh sách): {k, n, t, s, kick, text}; null = chưa.
    public static JsonObject? DueReminder() => Native.SyncNode("iptv.dueReminder") as JsonObject;

    // ---- Tiện ích hiển thị ----

    public static string S(JsonNode? n, string key) => n?[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";

    public static double D(JsonNode? n, string key) => n?[key] is JsonValue v && v.TryGetValue<double>(out var d) ? d : 0;

    public static bool B(JsonNode? n, string key) => n?[key] is JsonValue v && v.TryGetValue<bool>(out var b) && b;

    public static double NowSec() => Util.NowMs() / 1000.0;

    /// «19:00» giờ máy.
    public static string Clock(double t) => DateTimeOffset.FromUnixTimeMilliseconds((long)(t * 1000)).LocalDateTime.ToString("HH:mm");
}
