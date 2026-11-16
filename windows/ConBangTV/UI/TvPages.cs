using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using ConBangTV.Core;

namespace ConBangTV.UI;

/// <summary>
/// Truyền hình · Radio (IPTV): danh sách kênh M3U người xem tự thêm (app không kèm sẵn kênh) — nhóm, tìm theo tên / số kênh,
/// ★ yêu thích, chương trình đang phát + thanh tiến độ, trạng thái trận (danh sách thể thao). Như bản tivi (TvActivity) và Legacy.
/// Danh sách lớn (Xtream vài trăm nghìn mục) hiện theo trang 120 kênh.
/// </summary>
public sealed class TvPage : Page
{
    private const int PageSize = 120;
    private IptvFilter _filter = new();
    private int _offset;
    private long _version = -1;
    private bool _favsChosen;
    private readonly TextBox _search = new() { MinWidth = 260, Margin = new Thickness(0, 0, 10, 10) };
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromSeconds(30) };
    private readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly DispatcherTimer _searchGo = new() { Interval = TimeSpan.FromMilliseconds(450) };
    private readonly WrapPanel _cards = new();
    private readonly StackPanel _top = new();
    private readonly StackPanel _bottom = new();
    private JsonObject? _groups;
    private readonly Grid _searchBox = new();

    public TvPage()
    {
        MenuKey = "tv";
        _searchBox.Children.Add(_search);
        var ph = Ui.Dim("Tìm kênh / số kênh", 14, new Thickness(10, 6, 0, 0));
        ph.IsHitTestVisible = false;
        _searchBox.Children.Add(ph);
        _search.TextChanged += (_, _) => ph.Visibility = _search.Text == "" ? Visibility.Visible : Visibility.Collapsed;
        _search.TextChanged += (_, _) =>
        {
            _searchGo.Stop();
            _searchGo.Start();
        };
        _searchGo.Tick += (_, _) =>
        {
            _searchGo.Stop();
            _filter = _filter with { Q = _search.Text.Trim() };
            _offset = 0;
            _ = LoadCards(false);
        };
        _tick.Tick += (_, _) =>
        {
            if (!IsVisible) return;
            _ = LoadCards(true); // giờ trận / chương trình đổi theo phút
            _ = Iptv.AutoRefresh();
        };
        // Đang tải danh sách / lịch: dòng trạng thái; dữ liệu đổi (tải xong) thì vẽ lại
        _poll.Tick += (_, _) =>
        {
            if (!IsVisible) return;
            var st = Iptv.Status();
            var v = st["version"]?.GetValue<long>() ?? 0;
            if (v != _version) _ = Rebuild();
            else UpdateInfo(st);
        };
        Unloaded += (_, _) =>
        {
            _tick.Stop();
            _poll.Stop();
        };
        Loaded += (_, _) =>
        {
            _tick.Start();
            _poll.Start();
        };
    }

    protected override async Task Load()
    {
        Loading();
        await Rebuild();
        if (Iptv.ActiveList() != null) _ = RefreshList(false);
    }

    public override void Returned()
    {
        _ = Rebuild();
        _ = Iptv.AutoRefresh();
    }

    private static async Task RefreshList(bool force)
    {
        try
        {
            await Iptv.Refresh(force);
        }
        catch (Exception e)
        {
            Main.Toast(Util.Friendly(e));
        }
    }

    private TextBlock _info = Ui.Dim("");

    private void UpdateInfo(JsonObject st)
    {
        var l = st["active"] as JsonObject;
        if (l == null)
        {
            _info.Text = "";
            return;
        }
        var status = Iptv.S(st, "status");
        var text = Iptv.S(l, "name");
        if (status != "") text += " · " + status;
        else
        {
            if (Iptv.D(l, "count") > 0) text += $" · {Iptv.D(l, "count"):0} kênh";
            if (Iptv.D(l, "updated") > 0) text += " · cập nhật " + Iptv.Clock(Iptv.D(l, "updated") / 1000);
            if (Prefs.Kids) text += " · hồ sơ trẻ em: kênh thiếu nhi";
        }
        _info.Text = text;
    }

    private async Task Rebuild()
    {
        var st = Iptv.Status();
        _version = st["version"]?.GetValue<long>() ?? 0;
        var list = st["active"] as JsonObject;
        Body.Children.Clear();
        var head = new DockPanel { Margin = new Thickness(0, 10, 0, 6) };
        head.Children.Add(Ui.Text("Truyền hình · Radio", 21, weight: FontWeights.SemiBold, wrap: false));
        _info = Ui.Dim("", 14, new Thickness(14, 6, 0, 0));
        head.Children.Add(_info);
        Body.Children.Add(head);
        UpdateInfo(st);
        if (list == null)
        {
            Body.Children.Add(Ui.Dim("Chưa có danh sách kênh. App không kèm sẵn kênh: thêm địa chỉ danh sách M3U / M3U8 (hoặc tệp .m3u) mà bạn có quyền xem.",
                16, new Thickness(0, 30, 0, 16)));
            Body.Children.Add(Ui.Row(Ui.Pill("+  Thêm danh sách kênh", () => _ = TvLists.AskAdd(() => _ = Rebuild()))));
            _ = Dispatcher.BeginInvoke(() => FocusFirst(), DispatcherPriority.Loaded);
            return;
        }
        var bar = new WrapPanel();
        // Ô tìm giữ nguyên qua các lần vẽ lại (đang gõ dở không mất chữ): gỡ khỏi khung cũ trước
        (_searchBox.Parent as Panel)?.Children.Remove(_searchBox);
        bar.Children.Add(_searchBox);
        bar.Children.Add(Ui.Pill("Đổi danh sách", () => _ = ChooseList()));
        bar.Children.Add(Ui.Pill("⚙  Cài đặt Truyền hình", () => Main.Push(new TvSettingsPage())));
        Body.Children.Add(bar);
        Body.Children.Add(_top);
        Body.Children.Add(_cards);
        Body.Children.Add(_bottom);
        _top.Children.Clear();
        if (Iptv.S(list, "err") is { Length: > 0 } err && (Iptv.D(list, "count") == 0))
        {
            Body.Children.Add(Ui.Dim($"Chưa tải được danh sách «{Iptv.S(list, "name")}».\n{err}", 16, new Thickness(0, 20, 0, 0)));
        }
        _groups = await Iptv.Groups();
        var total = (int)Iptv.D(_groups, "total");
        var favs = (int)Iptv.D(_groups, "favs");
        if (!_favsChosen && total > 0)
        {
            _favsChosen = true;
            if (favs > 0) _filter = _filter with { Favs = true, Group = null };
        }
        var groupsRow = new WrapPanel { Margin = new Thickness(0, 4, 0, 8) };
        groupsRow.Children.Add(GroupPill($"★ Yêu thích  {favs}", _filter.Favs, () => _filter = _filter with { Favs = true, Group = null }));
        groupsRow.Children.Add(GroupPill($"Tất cả  {total}", !_filter.Favs && _filter.Group == null, () => _filter = _filter with { Favs = false, Group = null }));
        foreach (var g in _groups["groups"] as JsonArray ?? new JsonArray())
        {
            var id = (int)Iptv.D(g, "id");
            groupsRow.Children.Add(GroupPill($"{Iptv.S(g, "name")}  {Iptv.D(g, "count"):0}", !_filter.Favs && _filter.Group == id,
                () => _filter = _filter with { Favs = false, Group = id }));
        }
        _top.Children.Add(groupsRow);
        await LoadCards(true);
    }

    private Button GroupPill(string text, bool active, Action pick) => Ui.Pill(text, () =>
    {
        pick();
        _offset = 0;
        _ = Rebuild();
    }, active ? "active" : null);

    /// Vẽ lại các ô của trang hiện tại (keep: giữ ô đang chọn).
    private async Task LoadCards(bool keep)
    {
        var focusedKey = keep && Keyboard.FocusedElement is Button { Tag: string k } ? k : null;
        var page = await Iptv.Page(_filter, _offset, PageSize);
        var total = (int)Iptv.D(page, "total");
        _cards.Children.Clear();
        _bottom.Children.Clear();
        var items = page["items"] as JsonArray ?? new JsonArray();
        var i = _offset;
        foreach (var c in items)
        {
            var index = i++;
            _cards.Children.Add(Card(c!, index));
        }
        if (items.Count == 0)
        {
            var msg = _filter.Q != "" ? $"Không có kênh nào khớp «{_filter.Q}»."
                : _filter.Favs ? "Chưa có kênh yêu thích — nhấn phải chuột / phím Menu trên ô kênh để thêm."
                : Iptv.Status()["loading"]?.GetValue<bool>() == true ? "Đang tải danh sách kênh…"
                : Prefs.Kids ? "Danh sách này không có kênh thiếu nhi." : "Nhóm này không có kênh.";
            _bottom.Children.Add(Ui.Dim(msg, 16, new Thickness(0, 20, 0, 0)));
        }
        if (total > PageSize)
        {
            var row = new WrapPanel { Margin = new Thickness(0, 12, 0, 0) };
            if (_offset > 0) row.Children.Add(Ui.Pill("‹ Trang trước", () => { _offset = Math.Max(0, _offset - PageSize); _ = LoadCards(false); }));
            row.Children.Add(Ui.Dim($"  Kênh {_offset + 1}–{Math.Min(total, _offset + PageSize)} / {total}  ", 15, new Thickness(6, 8, 6, 0)));
            if (_offset + PageSize < total) row.Children.Add(Ui.Pill("Trang sau ›", () => { _offset += PageSize; _ = LoadCards(false); }));
            _bottom.Children.Add(row);
        }
        if (focusedKey != null)
        {
            await Dispatcher.BeginInvoke(() =>
                _cards.Children.OfType<Button>().FirstOrDefault(b => b.Tag as string == focusedKey)?.Focus(), DispatcherPriority.Loaded);
        }
    }

    private Button Card(JsonNode c, int index)
    {
        var now = Iptv.NowSec();
        var b = new Button
        {
            Width = 300, Height = 126, Margin = new Thickness(0, 0, 12, 12), Padding = new Thickness(12, 10, 12, 8), Tag = Iptv.S(c, "k"),
            HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch,
        };
        var root = new StackPanel();
        var top = new DockPanel();
        var logoBox = new Border { Width = 64, Height = 40, CornerRadius = new CornerRadius(6), Background = new SolidColorBrush(Color.FromRgb(0x26, 0x2B, 0x32)) };
        var img = new Image { Margin = new Thickness(3), Stretch = Stretch.Uniform };
        if (Iptv.S(c, "logo") is { Length: > 0 } logo) ImageLoader.SetUrl(img, logo);
        else logoBox.Child = new TextBlock { Text = Iptv.S(c, "n"), FontSize = 10, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(3), Foreground = Ui.Res("TextBrush") };
        if (logoBox.Child == null) logoBox.Child = img;
        top.Children.Add(logoBox);
        if (Iptv.B(c, "fav"))
        {
            var star = Ui.Text("★", 18, Ui.Res("Focus"));
            DockPanel.SetDock(star, Dock.Right);
            top.Children.Add(star);
        }
        var name = new TextBlock { TextWrapping = TextWrapping.Wrap, MaxHeight = 42, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(10, 0, 0, 0), FontSize = 15 };
        name.Inlines.Add(new System.Windows.Documents.Run(Iptv.S(c, "num") + "  ") { Foreground = Ui.Res("TextDim") });
        name.Inlines.Add(new System.Windows.Documents.Run(Iptv.S(c, "n")) { FontWeight = FontWeights.SemiBold });
        top.Children.Add(name);
        root.Children.Add(top);
        var bad = Iptv.S(c, "bad");
        var match = Iptv.S(c, "match");
        var line = Iptv.S(c, "matchLine");
        var prog = c["now"] as JsonObject;
        var next = c["next"] as JsonObject;
        var g = Iptv.B(c, "radio") ? "📻 " + Iptv.S(c, "g") : Iptv.B(c, "vod") ? "🎬 " + Iptv.S(c, "g") : Iptv.S(c, "g");
        string l1, l2 = "";
        Brush color = Ui.Res("TextBrush");
        double frac = -1;
        if (bad != "")
        {
            l1 = "Máy này không phát được";
            l2 = bad;
            color = new SolidColorBrush(Color.FromRgb(0xF0, 0xB4, 0x4C));
        }
        else if (line != "")
        {
            l1 = line;
            l2 = (Iptv.HasReminder(Iptv.S(c, "k"), null, true) ? "🔔 Nhắc lúc bóng lăn · " : "") + Iptv.S(c, "g");
            color = match switch
            {
                "live" => new SolidColorBrush(Color.FromRgb(0xFF, 0x61, 0x66)),
                "soon" => Ui.Res("Focus"),
                "over" => Ui.Res("TextDim"),
                _ => Ui.Res("TextBrush"),
            };
            if (match == "live") frac = (now - Iptv.D(c, "kick")) / (Iptv.D(c, "dur") * 60);
        }
        else if (prog != null)
        {
            var s = Iptv.D(prog, "s");
            var e = Iptv.D(prog, "e");
            l1 = $"{Iptv.S(prog, "t")}   {Iptv.Clock(s)}–{Iptv.Clock(e)}";
            l2 = next != null ? $"Tiếp: {Iptv.Clock(Iptv.D(next, "s"))} {Iptv.S(next, "t")}" : g;
            frac = (now - s) / Math.Max(1, e - s);
        }
        else
        {
            l1 = g;
        }
        root.Children.Add(new TextBlock { Text = l1, Foreground = color, FontSize = 14, Margin = new Thickness(0, 8, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis });
        if (frac >= 0)
        {
            var track = new Grid { Height = 4, Margin = new Thickness(0, 5, 0, 0), Background = new SolidColorBrush(Color.FromArgb(0x55, 0xFF, 0xFF, 0xFF)) };
            track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Clamp(frac, 0, 1), GridUnitType.Star) });
            track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1 - Math.Clamp(frac, 0, 1), GridUnitType.Star) });
            track.Children.Add(new Border { Background = Ui.Res("Focus") });
            root.Children.Add(track);
        }
        if (l2 != "") root.Children.Add(new TextBlock { Text = l2, Foreground = Ui.Res("TextDim"), FontSize = 12.5, Margin = new Thickness(0, 4, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis });
        b.Content = root;
        b.Opacity = bad != "" ? 0.55 : match == "over" ? 0.7 : 1;
        b.Click += (_, _) => _ = Open(c, index);
        b.MouseRightButtonUp += (_, e) =>
        {
            e.Handled = true;
            _ = Menu(c, index);
        };
        b.PreviewKeyDown += (_, e) =>
        {
            if (e.Key is not (Key.Apps or Key.M)) return;
            e.Handled = true;
            _ = Menu(c, index);
        };
        return b;
    }

    private async Task Open(JsonNode c, int index)
    {
        if (WatchLimit.Blocked() is { } blocked)
        {
            _ = Main.LimitReached(blocked, "", "", () => _ = Open(c, index));
            return;
        }
        // Trận còn hơn 30 phút mới đá: kênh chưa lên sóng — hỏi đặt nhắc thay vì mở ra màn lỗi
        if (Iptv.S(c, "match") == "later")
        {
            var kick = Iptv.D(c, "kick");
            var m = (long)Math.Ceiling((kick - Iptv.NowSec()) / 60);
            var left = m >= 24 * 60 ? $"{(m + 720) / 1440} ngày" : m >= 60 ? $"{m / 60} giờ {m % 60:00} phút" : $"{m} phút";
            var has = Iptv.HasReminder(Iptv.S(c, "k"), null, true);
            var r = await Main.Ask("Trận chưa bắt đầu",
                $"{Iptv.S(c, "n")}\nBóng lăn lúc {Iptv.KickText(kick)} (còn {left}).\nKênh trận đấu thường chỉ lên sóng trước giờ đá 15–30 phút.",
                new[] { has ? "Bỏ nhắc" : "Nhắc lúc bóng lăn", "Vẫn mở", "Đóng" });
            if (r == 0) ToggleKick(c);
            if (r != 1) return;
        }
        Main.PlayLive(_filter, index);
    }

    private void ToggleKick(JsonNode c)
    {
        var on = Iptv.ToggleReminder(Iptv.S(c, "k"), Iptv.S(c, "n"), Iptv.S(c, "n"), Iptv.D(c, "kick"), true);
        Main.Toast(on ? $"Sẽ nhắc lúc bóng lăn ({Iptv.KickText(Iptv.D(c, "kick"))}) — khi app đang mở." : "Đã bỏ nhắc.");
        _ = LoadCards(true);
    }

    /// Nhấn phải / phím Menu trên ô kênh.
    private async Task Menu(JsonNode c, int index)
    {
        var acts = new List<(string, Func<Task>)> { ("Xem", () => Open(c, index)) };
        var match = Iptv.S(c, "match");
        if (match is "later" or "soon")
            acts.Add((Iptv.HasReminder(Iptv.S(c, "k"), null, true) ? "Bỏ nhắc bóng lăn" : "🔔 Nhắc lúc bóng lăn", () => { ToggleKick(c); return Task.CompletedTask; }));
        if (match == "none" && !Iptv.B(c, "vod")) acts.Add(("Lịch phát sóng", () => { Main.Push(new TvGuidePage(_filter, index)); return Task.CompletedTask; }));
        var fav = Iptv.B(c, "fav");
        acts.Add((fav ? "Bỏ khỏi Yêu thích" : "★ Thêm vào Yêu thích", () =>
        {
            Iptv.SetFavorite(Iptv.S(c, "k"), !fav);
            Main.Toast(fav ? $"Đã bỏ {Iptv.S(c, "n")} khỏi Yêu thích." : $"Đã thêm {Iptv.S(c, "n")} vào Yêu thích.");
            return Rebuild();
        }));
        if (Iptv.S(c, "bad") != "")
            acts.Add(("Thử lại kênh này", () =>
            {
                Iptv.ClearBadFor(Iptv.S(c, "k"));
                return Open(c, index);
            }));
        var r = await Main.Ask(Iptv.S(c, "n"), "", acts.Select(a => a.Item1).Append("Huỷ").ToArray());
        if (r >= 0 && r < acts.Count) await acts[r].Item2();
    }

    private async Task ChooseList()
    {
        var lists = Iptv.Lists();
        var active = Iptv.S(Iptv.ActiveList(), "id");
        var labels = lists.Select(l => (Iptv.S(l, "id") == active ? "✓ " : "") + Iptv.S(l, "name") + (Iptv.D(l, "count") > 0 ? $"  ({Iptv.D(l, "count"):0} kênh)" : ""))
            .Append("+ Thêm danh sách…").Append("Quản lý danh sách, lịch phát sóng…").ToArray();
        var r = await Main.Ask("Danh sách kênh", "", labels);
        if (r < 0) return;
        if (r < lists.Count)
        {
            Iptv.SetActive(Iptv.S(lists[r], "id"));
            _favsChosen = false;
            _filter = new IptvFilter();
            _offset = 0;
            await Rebuild();
            _ = RefreshList(false);
        }
        else if (r == lists.Count) await TvLists.AskAdd(() => _ = Rebuild());
        else Main.Push(new TvSettingsPage());
    }
}

/// Thêm danh sách kênh: dán / gõ địa chỉ, hoặc chọn tệp .m3u trên máy.
public static class TvLists
{
    private static MainWindow Main => (MainWindow)Application.Current.MainWindow;

    public static async Task AskAdd(Action done)
    {
        var url = new TextBox { MinWidth = 420 };
        var name = new TextBox { MinWidth = 420, MaxLength = 40 };
        var box = new StackPanel();
        box.Children.Add(Ui.Dim("Địa chỉ danh sách M3U / M3U8 (http…)", 14, new Thickness(0, 0, 0, 4)));
        box.Children.Add(url);
        box.Children.Add(Ui.Dim("Tên hiện trong app (không bắt buộc)", 14, new Thickness(0, 12, 0, 4)));
        box.Children.Add(name);
        url.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            e.Handled = true;
            Main.CloseDialog(0);
        };
        _ = Main.Dispatcher.BeginInvoke(DispatcherPriority.Input, () => url.Focus());
        var r = await Main.Ask("Thêm danh sách kênh", "App không kèm sẵn kênh — chỉ thêm danh sách bạn có quyền xem.",
            new[] { "Thêm", "Chọn tệp .m3u…", "Huỷ" }, box);
        JsonObject? l = null;
        if (r == 0)
        {
            var u = url.Text.Trim();
            if (u.Length < 8 || !u.Contains('.'))
            {
                Main.Toast("Chưa có địa chỉ danh sách.");
                return;
            }
            l = Iptv.Add(u, name.Text.Trim());
        }
        else if (r == 1)
        {
            var dlg = new Microsoft.Win32.OpenFileDialog { Filter = "Danh sách kênh (*.m3u;*.m3u8;*.txt)|*.m3u;*.m3u8;*.txt|Mọi tệp|*.*", Title = "Chọn tệp danh sách kênh" };
            if (dlg.ShowDialog(Main) != true) return;
            try
            {
                l = Iptv.AddFile(dlg.FileName, name.Text.Trim());
            }
            catch (Exception e)
            {
                Main.Toast(Util.Friendly(e));
                return;
            }
        }
        if (l == null) return;
        Main.Toast($"Đã thêm danh sách «{Iptv.S(l, "name")}» — đang tải kênh…");
        done();
        try
        {
            await Iptv.Refresh(true);
        }
        catch (Exception e)
        {
            Main.Toast(Util.Friendly(e));
        }
        done();
    }
}

/// Lịch phát sóng của một kênh: hôm qua / hôm nay / ngày mai, «Nhắc tôi» 5 phút trước giờ phát (khi app đang mở).
public sealed class TvGuidePage : Page
{
    private readonly IptvFilter _filter;
    private readonly int _index;
    private int _day;
    private JsonObject? _c;

    public TvGuidePage(IptvFilter filter, int index)
    {
        MenuKey = "tv";
        _filter = filter;
        _index = index;
    }

    protected override async Task Load()
    {
        Loading();
        _c = await Iptv.At(_filter, _index);
        Build();
    }

    private static double DayStart(int offset) => new DateTimeOffset(DateTime.Today.AddDays(offset)).ToUnixTimeSeconds();

    private void Build()
    {
        Body.Children.Clear();
        var c = _c;
        if (c == null)
        {
            Body.Children.Add(Ui.Dim("Danh sách kênh đang chọn không còn kênh này.", 16));
            return;
        }
        Body.Children.Add(Ui.Header(Iptv.S(c, "n")));
        Body.Children.Add(Ui.Dim($"Kênh {Iptv.S(c, "num")} · {Iptv.S(c, "g")}{(Iptv.B(c, "fav") ? " · ★ Yêu thích" : "")}", 14, new Thickness(0, -8, 0, 12)));
        Body.Children.Add(Ui.Row(Ui.Pill("▶  Xem trực tiếp", () => Main.PlayLive(_filter, _index)),
            Ui.Pill("Hôm qua", () => { _day = -1; Build(); }, _day == -1 ? "active" : null),
            Ui.Pill("Hôm nay", () => { _day = 0; Build(); }, _day == 0 ? "active" : null),
            Ui.Pill("Ngày mai", () => { _day = 1; Build(); }, _day == 1 ? "active" : null)));
        var all = c["programmes"] as JsonArray ?? new JsonArray();
        var from = DayStart(_day);
        var to = DayStart(_day + 1);
        var rows = all.Where(p => Iptv.D(p, "s") >= from && Iptv.D(p, "s") < to).ToList();
        if (rows.Count == 0)
        {
            Body.Children.Add(Ui.Dim(all.Count > 0 ? "Ngày này chưa có lịch."
                : Iptv.Epg()["url"] != null ? "Kênh này chưa có lịch phát sóng (lịch của danh sách không có kênh này)."
                : "Danh sách kênh không ghi địa chỉ lịch phát sóng. Đặt trong Cài đặt Truyền hình.", 16, new Thickness(0, 16, 0, 0)));
            return;
        }
        var now = Iptv.NowSec();
        Button? current = null;
        foreach (var p in rows)
        {
            var s = Iptv.D(p, "s");
            var e = Iptv.D(p, "e");
            var live = s <= now && now < e;
            var future = s > now;
            var remind = future && Iptv.HasReminder(Iptv.S(c, "k"), s, false);
            var detail = live ? $"ĐANG PHÁT · còn {Math.Max(1, Math.Ceiling((e - now) / 60)):0} phút · Enter: xem"
                : future ? $"{Iptv.Clock(s)}–{Iptv.Clock(e)} · " + (remind ? "🔔 Đã đặt nhắc (Enter: bỏ)" : "Enter: Nhắc tôi")
                : $"{Iptv.Clock(s)}–{Iptv.Clock(e)}";
            var content = new StackPanel();
            content.Children.Add(Ui.Text($"{Iptv.Clock(s)}    {Iptv.S(p, "t")}", 16, live ? Ui.Res("Brand") : future ? null : Ui.Res("TextDim"), FontWeights.SemiBold, false));
            content.Children.Add(Ui.Dim(detail, 13));
            var b = new Button { Content = content, HorizontalContentAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 0, 0, 4), MinWidth = 640 };
            b.Click += (_, _) =>
            {
                if (live) Main.PlayLive(_filter, _index);
                else if (future)
                {
                    var on = Iptv.ToggleReminder(Iptv.S(c, "k"), Iptv.S(c, "n"), Iptv.S(p, "t"), s, false);
                    Main.Toast(on ? $"Sẽ nhắc lúc {Iptv.Clock(Math.Max(now, s - 300))} (5 phút trước giờ phát, khi app đang mở)." : "Đã bỏ nhắc.");
                    Build();
                }
            };
            if (live) current = b;
            Body.Children.Add(b);
        }
        if (current != null) Dispatcher.BeginInvoke(() => current.BringIntoView(), DispatcherPriority.Loaded);
    }
}

/// Cài đặt Truyền hình: các danh sách (dùng / tải lại / đổi tên / xoá, thêm), lịch phát sóng (địa chỉ EPG, tải lại), phát.
public sealed class TvSettingsPage : Page
{
    private readonly TextBox _epg = new() { MinWidth = 460, Margin = new Thickness(0, 0, 10, 10) };

    public TvSettingsPage()
    {
        MenuKey = "tv";
    }

    protected override Task Load()
    {
        Build();
        return Task.CompletedTask;
    }

    private void Build()
    {
        Body.Children.Clear();
        Body.Children.Add(Ui.Header("Truyền hình — Cài đặt"));
        Body.Children.Add(Ui.Text("Danh sách kênh", 16, weight: FontWeights.SemiBold, margin: new Thickness(0, 4, 0, 8)));
        var active = Iptv.S(Iptv.ActiveList(), "id");
        foreach (var l in Iptv.Lists())
        {
            var id = Iptv.S(l, "id");
            var detail = Iptv.S(l, "err") is { Length: > 0 } err ? "Lỗi: " + err
                : Iptv.D(l, "updated") == 0 ? "Chưa tải" : $"{Iptv.D(l, "count"):0} kênh · cập nhật {Iptv.Clock(Iptv.D(l, "updated") / 1000)}";
            var from = Iptv.S(l, "url") is { Length: > 0 } u ? u : $"tệp «{Iptv.S(l, "src")}»";
            var row = new WrapPanel { Margin = new Thickness(0, 0, 0, 2) };
            row.Children.Add(Ui.Pill((id == active ? "✓  " : "") + Iptv.S(l, "name"), () =>
            {
                Iptv.SetActive(id);
                _ = Iptv.Refresh(false);
                Build();
            }, id == active ? "active" : null, 260));
            row.Children.Add(Ui.Pill("Tải lại", async () =>
            {
                Iptv.SetActive(id);
                Main.Toast("Đang tải lại danh sách…");
                try
                {
                    await Iptv.Refresh(true);
                    Main.Toast("Đã tải lại danh sách.");
                }
                catch (Exception e)
                {
                    Main.Toast(Util.Friendly(e));
                }
                Build();
            }));
            row.Children.Add(Ui.Pill("Đổi tên", async () =>
            {
                var box = new TextBox { Text = Iptv.S(l, "name"), MinWidth = 300, MaxLength = 40 };
                _ = Dispatcher.BeginInvoke(DispatcherPriority.Input, () => { box.Focus(); box.SelectAll(); });
                if (await Main.Ask("Đổi tên danh sách", "", new[] { "Lưu", "Huỷ" }, box) == 0) Iptv.Rename(id, box.Text.Trim());
                Build();
            }));
            row.Children.Add(Ui.Pill("Xoá", async () =>
            {
                if (!await Main.Confirm($"Xoá danh sách «{Iptv.S(l, "name")}»?", "", "Xoá")) return;
                Iptv.Remove(id);
                Build();
            }));
            var t = Ui.Dim($"{detail} · {from}", 13.5);
            t.VerticalAlignment = VerticalAlignment.Center;
            t.Margin = new Thickness(6, 0, 0, 10);
            row.Children.Add(t);
            Body.Children.Add(row);
        }
        Body.Children.Add(Ui.Row(Ui.Pill("+  Thêm danh sách (địa chỉ / tệp M3U)", () => _ = TvLists.AskAdd(Build))));
        Body.Children.Add(Ui.Dim("App không kèm sẵn kênh. Thêm danh sách M3U / M3U8 mà bạn có quyền xem; app đọc nhóm, logo, đài radio và địa chỉ lịch phát sóng ghi " +
            "trong danh sách. Danh sách theo địa chỉ tự tải lại khi cũ; danh sách từ tệp thì thêm lại khi có tệp mới.", 13.5, new Thickness(0, 4, 0, 0)));

        Body.Children.Add(Ui.Text("Lịch phát sóng", 16, weight: FontWeights.SemiBold, margin: new Thickness(0, 18, 0, 8)));
        var epg = Iptv.Epg();
        _epg.Text = Iptv.S(epg, "override");
        Body.Children.Add(Ui.Dim("Địa chỉ EPG (XMLTV — .xml / .xml.gz). Để trống = lấy từ danh sách: " +
            (Iptv.S(Iptv.ActiveList(), "epg") is { Length: > 0 } e ? e : "danh sách không ghi"), 13.5, new Thickness(0, 0, 0, 6)));
        Body.Children.Add(Ui.Row(_epg, Ui.Pill("Lưu", async () =>
        {
            Iptv.SetEpg(_epg.Text.Trim());
            await ReloadGuide();
        }), Ui.Pill("Tải lại lịch ngay", () => _ = ReloadGuide())));
        var fetched = Iptv.D(epg, "fetched");
        Body.Children.Add(Ui.Dim(fetched > 0 ? $"{Iptv.D(epg, "channels"):0} kênh có lịch · tải lúc {Iptv.Clock(fetched / 1000)}" : "Chưa tải lịch.", 13.5));

        Body.Children.Add(Ui.Text("Phát", 16, weight: FontWeights.SemiBold, margin: new Thickness(0, 18, 0, 8)));
        Body.Children.Add(Ui.Row(
            Ui.Pill("Ẩn kênh máy không phát được: " + (Iptv.HideBad ? "Bật" : "Tắt"), () => { Iptv.HideBad = !Iptv.HideBad; Build(); }),
            Ui.Pill("Nguồn lỗi thì tự sang nguồn khác: " + (Iptv.AutoSource ? "Bật" : "Tắt"), () => { Iptv.AutoSource = !Iptv.AutoSource; Build(); }),
            Ui.Pill("Xoá dấu «không phát được»", () =>
            {
                Iptv.ClearBad();
                Main.Toast("Đã xoá — lần mở sau app thử lại các kênh đó.");
            })));
        Body.Children.Add(Ui.Dim("Danh sách có nhiều nguồn cho một kênh thì nguồn lỗi tự sang nguồn sau. Luồng phát đi thẳng tới máy chủ của kênh " +
            "(kèm Referer / User-Agent danh sách ghi).", 13.5, new Thickness(0, 4, 0, 0)));
    }

    private async Task ReloadGuide()
    {
        Main.Toast("Đang tải lịch phát sóng…");
        try
        {
            await Iptv.RefreshGuide(true);
            Main.Toast($"Đã tải lịch: {Iptv.D(Iptv.Epg(), "channels"):0} kênh có lịch.");
        }
        catch (Exception e)
        {
            Main.Toast(Util.Friendly(e));
        }
        Build();
    }
}
