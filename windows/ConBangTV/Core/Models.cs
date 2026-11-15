namespace ConBangTV.Core;

// Dữ liệu đọc từ trang phim — giống hệt bản Android (Site.kt) / iPad (Models.swift), để sửa bộ đọc trang song song.

/// Imdb: điểm IMDb (chỉ dữ liệu KKPhim có — ImdbTop.cs); null = không có / quá ít lượt chấm.
public sealed record Film(string Url, string Title, string? Poster, string? Badge, Imdb? Imdb = null);

public sealed record FilmSection(string Title, List<Film> Films);

public sealed record Category(string Title, string Url);

/// Đo nhanh một trang: thời gian tải trang chủ (ms) và số phim đọc được (0 = có thể là trang chặn của nhà mạng).
public sealed record SiteCheck(int Ms, int Films);

/// MovedTo: trang đã chuyển sang tên miền khác (theo chuyển hướng) → gốc mới.
public sealed class Home
{
    public List<FilmSection> Sections = new();
    public List<Category> Categories = new();
    public string? MovedTo;
}

/// Sections: trang chia nhóm (vd lịch chiếu theo ngày) — khi có thì hiển thị thay cho Films.
public sealed class FilmPage
{
    public List<Film> Films = new();
    public string? NextUrl;
    public List<FilmSection> Sections = new();
}

public sealed record Episode(string Title, string Url);

/// Một danh sách tập, vd "Việt Sub" / "Thuyết Minh".
public sealed record EpisodeGroup(string Name, List<Episode> Episodes);

/// Seasons: mỗi nhóm là một mùa (phim bộ của dexter.pw; nhóm tập đặc biệt — nếu có — đứng cuối) chứ không phải một bản
/// (Vietsub / Thuyết Minh) của cùng các tập. Lõi Rust nhận lại FilmDetail (kk.source, home.markSeen…) nên phải giữ đủ trường.
public sealed class FilmDetail
{
    /// Tên nhóm tập đặc biệt (mùa 0) của phim chia mùa.
    public const string Specials = "Tập đặc biệt";

    public required string Url;
    public required string Title;
    public string? OtherTitle;
    public string? Poster;
    public string? Description;
    public string? Info;
    public List<EpisodeGroup> Groups = new();
    public bool Seasons;

    /// Bản: số tập của bản nhiều tập nhất. Mùa: tổng số tập (mùa mới ra tập là tăng — để báo «có tập mới»).
    public int EpisodeCount => Groups.Count == 0 ? 0 : Seasons ? Groups.Sum(g => g.Episodes.Count) : Groups.Max(g => g.Episodes.Count);

    /// Bản: tập mới nhất của bản nhiều tập nhất (bản Vietsub thường ra trước Thuyết Minh). Mùa: tập cuối của mùa cuối (không
    /// tính nhóm tập đặc biệt).
    public Episode? LatestEpisode => Groups.Count == 0 ? null
        : Seasons ? (Groups.LastOrDefault(g => g.Name != Specials) ?? Groups[^1]).Episodes.LastOrDefault()
        : Groups.MaxBy(g => g.Episodes.Count)!.Episodes.LastOrDefault();

    public EpisodeGroup? GroupOf(string epUrl) => Groups.FirstOrDefault(g => g.Episodes.Any(e => e.Url == epUrl));
}

public sealed record Server(string Label, string Type);

/// Một phụ đề rời chọn được trong trình phát (dexter.pw: kho OpenSubtitles / Subsource). Lang: "vi", "en".
public sealed record SubTrack(string Label, string Url, string Lang);

/// Link phát của một server: iframe trình phát / trang tập, hoặc luồng .m3u8 (kèm phụ đề rời nếu có).
/// File: tệp video phát thẳng bằng &lt;video&gt; (MP4 của CLB Phim Xưa), không phải trang trình phát.
/// Hls: luồng HLS dù đường dẫn không có đuôi .m3u8 (dexter.pw /api/s/…) — phát bằng hls.html với bản hls.js đầy đủ (âm thanh
/// tách rời). Subs: phụ đề chọn được (trình phát chọn sẵn theo ngôn ngữ ưa dùng); SubsLater: địa chỉ danh sách phụ đề trang còn
/// đang tìm — trình phát hỏi lại sau (Dexter.SubtitlesFrom). Lõi nhận lại Video (EpisodeSource.Links) nên phải giữ đủ trường.
public sealed record Video(string Url, string? Subtitle = null, bool File = false, bool Hls = false, List<SubTrack>? Subs = null,
    string? SubsLater = null);

/// Cách phát một tập: player.php → iframe; PageMode → mở thẳng trang tập; Next → trang Next.js / trang API.
public sealed class EpisodeSource
{
    public required string EpUrl;
    public List<Server> Servers = new();
    public string PostId = "";
    public string Ep = "";
    public string Sv = "";
    public string? PlayerUrl;
    public string? DirectEmbed;
    public bool PageMode;
    public Dictionary<string, Video> Links = new();
    public bool Next;

    /// Loại server "Trình phát của trang" (mở thẳng trang tập) khi trang PageMode có thêm server dự phòng KKPhim.
    public const string PageServer = "page";

    /// Chỉ có trình phát của trang tập (không có server nào khác để chọn, kể cả server dự phòng KKPhim).
    public bool PageOnly => PageMode && Servers.All(s => s.Type != PageServer);
}

public sealed class HistoryItem
{
    public string FilmUrl { get; set; } = "";
    public string Title { get; set; } = "";
    public string? Poster { get; set; }
    public string EpTitle { get; set; } = "";
    public string EpUrl { get; set; } = "";
    /// ms kể từ 1970
    public long Time { get; set; }
}

/// Phim theo dõi: Count = số tập lần kiểm gần nhất, Seen = số tập lúc người xem mở phim lần cuối.
public sealed class Follow
{
    public string FilmUrl { get; set; } = "";
    public string Title { get; set; } = "";
    public string? Poster { get; set; }
    public int Count { get; set; }
    public string Latest { get; set; } = "";
    public int Seen { get; set; }
    public long? T { get; set; }

    public int NewCount => Math.Max(0, Count - Seen);
}

/// Người xem (hồ sơ) — cùng bản TV / iPad. Id "" = người xem đầu tiên (khoá cũ); Color = chỉ số trong Prefs.ProfileColors;
/// Pin = mã băm của mã PIN (null = không khoá).
public sealed class Profile
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public int Color { get; set; }
    public string? Pin { get; set; }

    [System.Text.Json.Serialization.JsonIgnore]
    public bool Locked => Pin != null;

    /// Chữ cái đầu tên (trên vòng tròn màu).
    [System.Text.Json.Serialization.JsonIgnore]
    public string Initial => Name.Trim().Length > 0 ? Name.Trim()[..1].ToUpperInvariant() : "?";
}

/// Lỗi có câu báo tiếng Việt cho người xem.
public sealed class AppError : Exception
{
    public AppError(string message) : base(message) { }
}
