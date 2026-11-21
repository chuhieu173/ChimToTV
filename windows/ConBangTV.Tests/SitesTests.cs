using ConBangTV.Core;
using Xunit;

namespace ConBangTV.Tests;

/// Thêm nhiều trang phim một lần (dán nhiều dòng) — cùng ca với linux/core (prefs.rs splits_sites, tests/sites.rs).
/// Chỉ dùng tên miền bịa (*.example).
public class SitesTests : PrefsTest
{
    private const string Paste = "# chú thích: phim-x.example không tính\n" +
                                 "phim-a.example\r\n" +
                                 "  https://www.phim-b.example/xem/1?x=2#t  \n" +
                                 "http://PHIM-A.example/\n" +
                                 "\"phim-c.example:8080/abc\", <https://phim-d.example>;\n" +
                                 "chữ thường không có dấu chấm\n" +
                                 "bản 1.5 và 2.21 (phim-e.example).\n" +
                                 "localhost bad..host .an.example\n" +
                                 "kkphim.com\n";

    [Fact]
    public void SplitsNormalizesAndDedups()
    {
        Assert.Equal(new[]
        {
            "https://phim-a.example", "https://www.phim-b.example", "https://phim-c.example:8080", "https://phim-d.example",
            "https://phim-e.example", Prefs.KkSite,
        }, Prefs.SplitSites(Paste));
        // «bad..host» là tên sai; «localhost», «.an.example», số bản: bỏ qua không báo
        Assert.Equal(1, Prefs.InvalidSites(Paste));
        // «v.v.», «e.g.», «tr.5» trong câu: bỏ qua không báo; IP đủ 4 phần, xn--… vẫn nhận
        const string abbr = "Các trang phim-a.example, phim-b.example v.v. (e.g. tr.5)\nhttp://10.0.0.5:8080/x xn--fiq228c.xn--p1ai";
        Assert.Equal(new[] { "https://phim-a.example", "https://phim-b.example", "http://10.0.0.5:8080", "https://xn--fiq228c.xn--p1ai" },
            Prefs.SplitSites(abbr));
        Assert.Equal(0, Prefs.InvalidSites(abbr));
        Assert.True(Prefs.PlausibleHost("https://phim.example:8443/a@b"));
        Assert.False(Prefs.PlausibleHost("v.v") || Prefs.PlausibleHost("tr.5"));
        Assert.Empty(Prefs.SplitSites(""));
        Assert.Empty(Prefs.SplitSites("# chỉ có chú thích\n\n   \n"));
        Assert.Equal(new[] { "https://www.phim-a.example" }, Prefs.SplitSites("www.phim-a.example\nphim-a.example/\nhttps://phim-a.example"));
        Assert.Equal("phim-a.example", Prefs.SiteKey("http://WWW.Phim-A.example/xem/"));
        Assert.Equal("phim-a.example", Prefs.SiteKey("phim-a.example"));
        Assert.Equal("phim-a.example:8443", Prefs.SiteKey("https://phim-a.example:8443"));
        Assert.Equal("kkphim.com", Prefs.SiteKey(Prefs.KkSite));
    }

    [Fact]
    public void AddManyKeepsCurrentSiteAndSkipsExisting()
    {
        Prefs.Sites = new() { "https://phim-a.example", "https://www.phim-b.example/xem" };
        Prefs.BaseUrl = "https://phim-a.example";
        var r = Prefs.AddSites("phim-c.example\nhttp://www.phim-a.example/\nhttps://phim-d.example/tap-1?sv=2   PHIM-B.example\nphim-c.example\nbad..host\n");
        Assert.Equal(new[] { "https://phim-c.example", "https://phim-d.example" }, r.Added);
        Assert.Equal(2, r.Existing);
        Assert.Equal(1, r.Invalid);
        Assert.Equal(new[] { "https://phim-a.example", "https://www.phim-b.example/xem", "https://phim-c.example", "https://phim-d.example" },
            Prefs.Sites);
        Assert.Equal("https://phim-a.example", Prefs.BaseUrl);
    }

    [Fact]
    public void NothingNewChangesNothing()
    {
        Prefs.Sites = new() { "https://phim-a.example" };
        var r = Prefs.AddSites("www.phim-a.example\n# phim-z.example\nchữ không phải trang");
        Assert.Empty(r.Added);
        Assert.Equal((1, 0), (r.Existing, r.Invalid));
        Assert.Equal(new[] { "https://phim-a.example" }, Prefs.Sites);
        r = Prefs.AddSites("bad..host");
        Assert.Empty(r.Added);
        Assert.Equal((0, 1), (r.Existing, r.Invalid));
        Assert.Equal(new[] { "https://phim-a.example" }, Prefs.Sites);
    }

    [Fact]
    public void SingleSiteIsAddedAtTheEnd()
    {
        var presets = Prefs.Sites;
        var r = Prefs.AddSites("  phim-moi.example/  ");
        Assert.Equal(new[] { "https://phim-moi.example" }, r.Added);
        Assert.Equal(presets.Append("https://phim-moi.example"), Prefs.Sites);
    }

    [Fact]
    public void Texts()
    {
        Assert.Equal("Đã thêm phim-a.example vào danh sách trang phim.", new AddSitesResult(new() { "https://www.phim-a.example" }, 0, 0).AddedText());
        Assert.Equal("Đã thêm 2 trang: a1.example, b2.example (bỏ qua 1 đã có).",
            new AddSitesResult(new() { "https://a1.example", "https://b2.example:8080" }, 1, 0).AddedText());
        Assert.Equal("Đã thêm 6 trang: s1.example, s2.example, s3.example… (+3) (2 tên miền không hợp lệ).",
            new AddSitesResult(Enumerable.Range(1, 6).Select(i => $"https://s{i}.example").ToList(), 0, 2).AddedText());
        Assert.Equal("Chưa có tên miền hợp lệ (vd ten-trang.example).", new AddSitesResult(new(), 0, 0).NoneText());
        Assert.Equal("Trang này đã có trong danh sách.", new AddSitesResult(new(), 1, 0).NoneText());
        Assert.Equal("Các trang này đã có trong danh sách.", new AddSitesResult(new(), 3, 1).NoneText());
    }
}
