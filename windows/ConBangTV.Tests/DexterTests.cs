using System.Text.Json;
using ConBangTV.Core;
using Xunit;

namespace ConBangTV.Tests;

/// dexter.pw ở phía app WPF: phụ đề ưa dùng / độ lệch (Prefs), phim chia mùa (FilmDetail.Seasons) và các trường mới của Video —
/// lõi Rust nhận lại FilmDetail / EpisodeSource (kk.source, home.markSeen…) nên tên trường JSON phải khớp models.rs.
public class DexterTests : PrefsTest
{
    [Fact]
    public void SubLangIsPerProfileAndDefaultsToVietnamese()
    {
        Assert.Equal("vi", Prefs.SubLang);
        Prefs.SubLang = "off";
        Assert.Equal("off", Prefs.SubLang);
        var bo = Prefs.AddProfile("Bố");
        Prefs.SwitchProfile(bo.Id);
        Assert.Equal("vi", Prefs.SubLang);
        Prefs.SubLang = "en";
        Prefs.SwitchProfile("");
        Assert.Equal("off", Prefs.SubLang);
    }

    [Fact]
    public void VideoQualityIsPerProfileAndDefaultsToAuto()
    {
        Assert.Equal(0, Prefs.VideoQuality);
        Prefs.VideoQuality = 2160;
        var bo = Prefs.AddProfile("Bố");
        Prefs.SwitchProfile(bo.Id);
        Assert.Equal(0, Prefs.VideoQuality);
        Prefs.VideoQuality = 720;
        Prefs.SwitchProfile("");
        Assert.Equal(2160, Prefs.VideoQuality);
    }

    [Fact]
    public void SubDelayPerEpisodeKeepsLatest100()
    {
        const string ep = "https://dexter.pw/watch/354912-coco";
        Assert.Equal(0, Prefs.SubDelay(ep));
        Prefs.SetSubDelay(ep, 0.5);
        Assert.Equal(0.5, Prefs.SubDelay(ep));
        Prefs.SetSubDelay(ep, -1.5);
        Assert.Equal(-1.5, Prefs.SubDelay(ep));
        Prefs.SetSubDelay(ep, 0);
        Assert.Equal(0, Prefs.SubDelay(ep));

        for (var i = 0; i < 105; i++) Prefs.SetSubDelay($"https://dexter.pw/watch/show/1405-dexter/1/{i}", 1);
        // chỉnh lại tập 5 → thành mới nhất, không bị bỏ
        Prefs.SetSubDelay("https://dexter.pw/watch/show/1405-dexter/1/5", 2);
        Prefs.SetSubDelay("https://dexter.pw/watch/show/1405-dexter/1/200", 1);
        Assert.Equal(0, Prefs.SubDelay("https://dexter.pw/watch/show/1405-dexter/1/0"));
        Assert.Equal(0, Prefs.SubDelay("https://dexter.pw/watch/show/1405-dexter/1/6"));
        Assert.Equal(1, Prefs.SubDelay("https://dexter.pw/watch/show/1405-dexter/1/7"));
        Assert.Equal(2, Prefs.SubDelay("https://dexter.pw/watch/show/1405-dexter/1/5"));
        Assert.Equal(1, Prefs.SubDelay("https://dexter.pw/watch/show/1405-dexter/1/200"));
    }

    private static List<Episode> Eps(int season, int n) =>
        Enumerable.Range(1, n).Select(i => new Episode($"Tập {i}", $"https://dexter.pw/watch/show/1405-dexter/{season}/{i}")).ToList();

    [Fact]
    public void SeasonsCountAllEpisodesAndLatestIsLastSeason()
    {
        var d = new FilmDetail
        {
            Url = "https://dexter.pw/show/1405-dexter", Title = "Dexter", Seasons = true,
            Groups = new() { new("Mùa 1", Eps(1, 12)), new("Mùa 2", Eps(2, 3)), new(FilmDetail.Specials, Eps(0, 2)) },
        };
        Assert.Equal(17, d.EpisodeCount);
        Assert.Equal("https://dexter.pw/watch/show/1405-dexter/2/3", d.LatestEpisode?.Url);

        // Phim chia bản (Vietsub / Thuyết Minh): như cũ — bản nhiều tập nhất
        d.Seasons = false;
        Assert.Equal(12, d.EpisodeCount);
        Assert.Equal("https://dexter.pw/watch/show/1405-dexter/1/12", d.LatestEpisode?.Url);
    }

    [Fact]
    public void NewFieldsRoundTripWithCoreJsonNames()
    {
        const string core = """
            {"url":"https://dexter.pw/api/s/20/tv/1405/1/2","subtitle":null,"file":false,"hls":true,
             "subs":[{"label":"Tiếng Việt 1","url":"https://dexter.pw/api/subs/file/tv/1405/1/2/a.vtt","lang":"vi"}],
             "subsLater":"https://dexter.pw/api/subs/list/tv/1405/1/2"}
            """;
        var v = JsonSerializer.Deserialize<Video>(core, Native.Json)!;
        Assert.True(v.Hls);
        Assert.Equal("vi", Assert.Single(v.Subs!).Lang);
        Assert.Equal("https://dexter.pw/api/subs/list/tv/1405/1/2", v.SubsLater);
        var back = JsonSerializer.Serialize(v, Native.Json);
        Assert.Contains("\"hls\":true", back);
        Assert.Contains("\"subsLater\":", back);
        Assert.Contains("\"lang\":\"vi\"", back);

        var d = JsonSerializer.Deserialize<FilmDetail>("""{"url":"u","title":"t","groups":[],"seasons":true}""", Native.Json)!;
        Assert.True(d.Seasons);
        Assert.Contains("\"seasons\":true", JsonSerializer.Serialize(d, Native.Json));
        // JSON cũ (không có trường mới) vẫn đọc được
        var old = JsonSerializer.Deserialize<Video>("""{"url":"https://x/a.m3u8","subtitle":null,"file":false}""", Native.Json)!;
        Assert.False(old.Hls);
        Assert.Null(old.Subs);
    }
}
