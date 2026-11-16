using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using ConBangTV.Core;
using ConBangTV.UI;

namespace ConBangTV.Player;

/// <summary>
/// Trình phát truyền hình / radio (IPTV) bằng libmpv — mpv tự đọc mọi loại luồng (HLS, HTTP-FLV, TS liền, DASH, đài MP3 / AAC
/// kèm tên bài ICY), gửi Referer / User-Agent riêng của nguồn. Cùng cách chạy với bản tivi (LiveActivity) và Legacy: nguồn lỗi
/// tự sang nguồn sau; hỏng hết nguồn thì tải lại danh sách (cũ quá 10 phút) tìm link mới một lần; trận sắp / đang đá mà chưa có
/// hình thì chờ, tải lại danh sách, thử lại mỗi 20 giây; link giả «no-signal» / hình chờ ngắn không phát; đài radio hiện thẻ đài.
/// Hình mpv là cửa sổ con (WPF không vẽ đè được): thanh trên / dưới và bảng kênh nằm cạnh khung hình, tự ẩn sau 6 giây.
/// Phím: ▲ ▼ / PgUp PgDn đổi kênh, Enter hiện nút, ◀ / M bảng kênh (phim: ◀ ▶ tua 10 giây), số 0–9 gõ số kênh, Space tạm dừng,
/// G lịch phát sóng, Esc đóng bảng / nút rồi mới thoát.
/// </summary>
public sealed class LiveView : UserControl
{
    private readonly MainWindow _main;
    private NativeVideo? _video;
    private IptvFilter _filter = new();
    private int _index;
    private int _total;
    private JsonObject? _ch;
    private int _source;
    private int _token;
    private bool _started;
    private long _startedAt;
    private long _openedAt;
    private int _reopens;
    private bool _listChecked;
    private bool _radio;
    private string? _icy;
    private string? _radioDesc;
    private long _pausedAt;
    private double _delay;
    private bool _limitWarned;
    private int _ticks;
    private string _digits = "";
    private bool _waitingRetry;

    private readonly ContentControl _videoHost = new() { Focusable = false };
    private readonly Grid _stage = new() { Background = Brushes.Black };
    private readonly DockPanel _top = new() { Background = new SolidColorBrush(Color.FromRgb(0x0E, 0x10, 0x14)) };
    private readonly StackPanel _bottom = new() { Background = new SolidColorBrush(Color.FromRgb(0x0E, 0x10, 0x14)) };
    private readonly Border _panel = new() { Width = 360, Background = Ui.Res("Surface"), Visibility = Visibility.Collapsed };
    private readonly StackPanel _panelList = new();
    private readonly ScrollViewer _panelScroll;
    private readonly TextBlock _panelTitle = Ui.Dim("", 14, new Thickness(16, 12, 16, 8));
    private readonly TextBlock _num = Ui.Text("", 18, Ui.Res("TextDim"), wrap: false, margin: new Thickness(0, 0, 12, 0));
    private readonly TextBlock _title = Ui.Text("", 19, weight: FontWeights.SemiBold, wrap: false);
    private readonly TextBlock _badge = new() { FontSize = 13, FontWeight = FontWeights.Bold, Foreground = Brushes.White, Padding = new Thickness(9, 3, 9, 3) };
    private readonly Border _badgeBox = new() { CornerRadius = new CornerRadius(5), Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _clock = Ui.Dim("", 16, new Thickness(14, 0, 0, 0));
    private readonly TextBlock _notice = Ui.Text("", 15, Ui.Res("Focus"), wrap: false, margin: new Thickness(14, 0, 0, 0));
    private readonly TextBlock _prog = Ui.Text("", 18, weight: FontWeights.SemiBold, wrap: false);
    private readonly TextBlock _next = Ui.Dim("", 14);
    private readonly TextBlock _time = Ui.Dim("", 14);
    private readonly Grid _track = new() { Height = 5, Margin = new Thickness(0, 8, 0, 0), Background = new SolidColorBrush(Color.FromArgb(0x55, 0xFF, 0xFF, 0xFF)) };
    private readonly WrapPanel _buttons = new() { Margin = new Thickness(0, 12, 0, 0) };
    private readonly Button _btnPlay, _btnLive, _btnSource, _btnFav, _btnGuide;
    private readonly StackPanel _status = new() { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 680 };
    private readonly ProgressBar _spinner = new() { IsIndeterminate = true, Width = 240, Margin = new Thickness(0, 0, 0, 14) };
    private readonly TextBlock _statusText = new() { FontSize = 18, Foreground = Ui.Res("TextBrush"), TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
    private readonly WrapPanel _statusButtons = new() { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 18, 0, 0) };
    private readonly Button _btnRetry;
    private readonly StackPanel _radioCard = new() { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Visibility = Visibility.Collapsed };
    private readonly Image _radioLogo = new() { Width = 150, Height = 150, Stretch = Stretch.Uniform };
    private readonly TextBlock _radioIcon = new() { Text = "📻", FontSize = 80, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock _radioName = Ui.Text("", 26, weight: FontWeights.SemiBold, wrap: false);
    private readonly TextBlock _radioSong = Ui.Text("", 19, Ui.Res("Brand"), FontWeights.SemiBold);
    private readonly TextBlock _radioInfo = Ui.Dim("", 15);
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly DispatcherTimer _hide = new() { Interval = TimeSpan.FromSeconds(6) };
    private readonly DispatcherTimer _digitsGo = new() { Interval = TimeSpan.FromMilliseconds(1500) };
    private readonly DispatcherTimer _noticeOff = new() { Interval = TimeSpan.FromSeconds(4) };

    public bool IsOpen { get; private set; }

    public LiveView(MainWindow main)
    {
        _main = main;
        Focusable = false;
        var root = new Grid { Background = Brushes.Black };
        root.ColumnDefinitions.Add(new ColumnDefinition());
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition());
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // Thanh trên
        _top.Margin = new Thickness(0);
        var topInner = new DockPanel { Margin = new Thickness(24, 12, 24, 12) };
        _badgeBox.Child = _badge;
        DockPanel.SetDock(_clock, Dock.Right);
        topInner.Children.Add(_clock);
        DockPanel.SetDock(_badgeBox, Dock.Right);
        topInner.Children.Add(_badgeBox);
        DockPanel.SetDock(_num, Dock.Left);
        topInner.Children.Add(_num);
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal };
        titleRow.Children.Add(_title);
        titleRow.Children.Add(_notice);
        topInner.Children.Add(titleRow);
        _top.Children.Add(topInner);
        Grid.SetRow(_top, 0);
        root.Children.Add(_top);

        // Khung hình: mpv / thẻ đài / trạng thái
        _stage.Children.Add(_videoHost);
        var logoBox = new Grid { Width = 170, Height = 170, Margin = new Thickness(0, 0, 0, 16) };
        logoBox.Children.Add(new Border { CornerRadius = new CornerRadius(10), Background = new SolidColorBrush(Color.FromRgb(0x26, 0x2B, 0x32)) });
        logoBox.Children.Add(_radioIcon);
        logoBox.Children.Add(_radioLogo);
        _radioIcon.VerticalAlignment = VerticalAlignment.Center;
        _radioCard.Children.Add(logoBox);
        foreach (var t in new[] { _radioName, _radioSong, _radioInfo })
        {
            t.HorizontalAlignment = HorizontalAlignment.Center;
            t.TextAlignment = TextAlignment.Center;
            t.Margin = new Thickness(0, 4, 0, 0);
            _radioCard.Children.Add(t);
        }
        _stage.Children.Add(_radioCard);
        _status.Children.Add(_spinner);
        _status.Children.Add(_statusText);
        _btnRetry = Ui.Pill("Thử lại", () => _ = Retry());
        _statusButtons.Children.Add(_btnRetry);
        _statusButtons.Children.Add(Ui.Pill("Kênh sau »", () => _ = Step(1)));
        _statusButtons.Children.Add(Ui.Pill("Quay lại", Close));
        _status.Children.Add(_statusButtons);
        _stage.Children.Add(_status);
        Grid.SetRow(_stage, 1);
        root.Children.Add(_stage);

        // Thanh dưới
        var bot = new StackPanel { Margin = new Thickness(24, 10, 24, 16) };
        var progRow = new DockPanel();
        DockPanel.SetDock(_next, Dock.Right);
        progRow.Children.Add(_next);
        progRow.Children.Add(_prog);
        bot.Children.Add(progRow);
        bot.Children.Add(_time);
        bot.Children.Add(_track);
        _btnPlay = Ui.Pill("Tạm dừng", TogglePlay);
        _btnLive = Ui.Pill("Về trực tiếp", GoLive);
        _btnSource = Ui.Pill("Nguồn 1/1", () => _ = NextSource());
        _btnFav = Ui.Pill("☆", ToggleFavorite);
        _btnGuide = Ui.Pill("Lịch", OpenGuide);
        _buttons.Children.Add(Ui.Pill("☰ Kênh", () => _ = TogglePanel()));
        _buttons.Children.Add(Ui.Pill("« Kênh trước", () => _ = Step(-1)));
        _buttons.Children.Add(_btnPlay);
        _buttons.Children.Add(Ui.Pill("Kênh sau »", () => _ = Step(1)));
        _buttons.Children.Add(_btnLive);
        _buttons.Children.Add(_btnSource);
        _buttons.Children.Add(_btnGuide);
        _buttons.Children.Add(_btnFav);
        _buttons.Children.Add(Ui.Pill("✕ Đóng", Close));
        bot.Children.Add(_buttons);
        _bottom.Children.Add(bot);
        Grid.SetRow(_bottom, 2);
        root.Children.Add(_bottom);

        // Bảng kênh
        var pd = new DockPanel();
        DockPanel.SetDock(_panelTitle, Dock.Top);
        pd.Children.Add(_panelTitle);
        _panelScroll = new ScrollViewer { Content = _panelList, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false, Padding = new Thickness(8, 0, 8, 12) };
        pd.Children.Add(_panelScroll);
        _panel.Child = pd;
        Grid.SetColumn(_panel, 1);
        Grid.SetRowSpan(_panel, 3);
        root.Children.Add(_panel);
        Content = root;

        _tick.Tick += (_, _) => Tick();
        _hide.Tick += (_, _) =>
        {
            _hide.Stop();
            AutoHide();
        };
        _digitsGo.Tick += (_, _) =>
        {
            _digitsGo.Stop();
            _ = JumpToNumber();
        };
        _noticeOff.Tick += (_, _) =>
        {
            _noticeOff.Stop();
            _notice.Text = "";
        };
        foreach (var b in KeyNavButtons()) b.GotKeyboardFocus += (_, _) => BumpHide();
    }

    private IEnumerable<Button> KeyNavButtons() => _buttons.Children.OfType<Button>().Concat(_statusButtons.Children.OfType<Button>());

    // ---- Mở / đóng ----

    public void Open(IptvFilter filter, int index)
    {
        IsOpen = true;
        _filter = filter;
        _index = index;
        _video ??= NativeVideo.Create();
        if (_video != null) _videoHost.Content = _video.Host;
        _tick.Start();
        SetControls(true);
        if (_video == null)
        {
            ShowError("Máy thiếu thư viện phát libmpv-2.dll — không phát được truyền hình.", false);
            return;
        }
        _ = PlayAt(index);
    }

    public void Close()
    {
        if (!IsOpen) return;
        IsOpen = false;
        _token++;
        _tick.Stop();
        _hide.Stop();
        WatchLimit.Flush();
        _video?.Stop();
        _video?.Dispose();
        _video = null;
        _videoHost.Content = null;
        _main.LiveClosed();
    }

    private async Task PlayAt(int index)
    {
        var t = ++_token;
        _video?.Stop();
        _started = false;
        ShowLoading("Đang mở kênh…");
        var ch = await Iptv.At(_filter, index);
        if (t != _token || !IsOpen) return;
        if (ch == null)
        {
            ShowError("Danh sách không còn kênh này.", false);
            return;
        }
        _index = index;
        _total = (int)Iptv.D(ch, "total");
        _ch = ch;
        _source = 0;
        _listChecked = false;
        var urls = Urls();
        while (_source + 1 < urls.Count && Iptv.S(urls[_source], "bad") != "") _source++;
        _reopens = 0;
        OpenSource();
        if (_panel.Visibility == Visibility.Visible) _ = BuildPanel(false);
    }

    private List<JsonNode> Urls() => (_ch?["urls"] as JsonArray)?.Where(x => x != null).Select(x => x!).ToList() ?? new List<JsonNode>();

    private async Task Step(int d)
    {
        if (_total < 2) return;
        await PlayAt((_index + d + _total) % _total);
        BumpHide();
    }

    private async Task NextSource()
    {
        var urls = Urls();
        if (urls.Count < 2) return;
        _source = (_source + 1) % urls.Count;
        _reopens = 0;
        OpenSource();
        await Task.CompletedTask;
    }

    private void OpenSource()
    {
        var t = ++_token;
        _video?.Stop();
        _started = false;
        _icy = null;
        _radioDesc = null;
        _delay = 0;
        _pausedAt = 0;
        _waitingRetry = false;
        var c = _ch;
        if (c == null || _video == null) return;
        SetRadio(Iptv.B(c, "radio"));
        UpdateLabels();
        var urls = Urls();
        if (_source >= urls.Count)
        {
            ShowError($"{Iptv.S(c, "n")} không có địa chỉ phát.", false);
            return;
        }
        var src = urls[_source];
        var url = Iptv.S(src, "url");
        if (Iptv.S(src, "bad") is { Length: > 0 } bad)
        {
            _ = SourceFailed(bad, true, t);
            return;
        }
        if (Iptv.IsPlaceholder(url))
        {
            // Link giả «không có tín hiệu»: đừng phát hình chờ — coi như nguồn chưa có
            _ = SourceFailed("Danh sách chưa có link phát (đang để hình «không có tín hiệu»).", false, t);
            return;
        }
        ShowLoading($"Đang mở {Iptv.S(c, "n")}…");
        Log.D("tv", $"{Iptv.S(c, "n")} (nguồn {_source + 1}/{urls.Count}) {url}");
        _openedAt = Util.NowMs();
        _video.LoadLive(url, Iptv.S(src, "referer").NullIfEmpty(), Iptv.S(src, "ua").NullIfEmpty());
    }

    // ---- Mỗi giây ----

    private void Tick()
    {
        if (!IsOpen || _video == null) return;
        _ticks++;
        var st = _video.Read();
        var playing = _started && !st.Paused && !st.Waiting;
        WatchLimit.Tick(playing);
        if (CheckLimit()) return;
        var c = _ch;
        // Đang báo lỗi / chờ trận (có nút): không xét lại trạng thái
        if (c != null && !_waitingRetry && _statusButtons.Visibility != Visibility.Visible)
        {
            if (!_started)
            {
                if (st.Err != null) _ = SourceFailed($"Không mở được luồng ({st.Err}).", false, _token);
                else if (st.Ready && !_checking) _ = OnStarted(st);
                else if (Util.NowMs() - _openedAt > 25_000) _ = SourceFailed("Máy chủ của kênh không trả lời (quá 25 giây).", false, _token);
            }
            else if (st.Err != null) ReopenLater("đứt");
            else if (st.Ended)
            {
                if (Iptv.B(c, "vod")) ShowError($"Đã xem hết {Iptv.S(c, "n")}.", true, "Xem lại");
                else ReopenLater("hết");
            }
        }
        if (_started)
        {
            if (playing && _reopens > 0 && Util.NowMs() - _startedAt > 60_000) _reopens = 0;
            RadioTick();
            _clock.Text = st.Waiting ? "Đang tải…  " + DateTime.Now.ToString("HH:mm") : DateTime.Now.ToString("HH:mm");
        }
        UpdateBadge(st);
        if (Iptv.B(c, "vod") || _ticks % 15 == 0) UpdateProgramme(st);
    }

    private bool _checking;

    private async Task OnStarted(NativeVideo.State st)
    {
        var c = _ch!;
        // Danh sách phát là đoạn phim ngắn có hồi kết (hình chờ «không có tín hiệu» thay cho luồng trực tiếp) — mpv báo độ dài
        // cả cho luồng trực tiếp: độ dài ngắn thì đọc danh sách phát (#EXT-X-ENDLIST) mới kết luận
        if (!Iptv.B(c, "vod") && st.D is > 0 and < 120 && _video?.Info().Format == "hls" && Urls().ElementAtOrDefault(_source) is { } src)
        {
            var t = _token;
            _checking = true;
            var ph = await Iptv.CheckPlaceholder(Iptv.S(src, "url"), Iptv.S(src, "referer").NullIfEmpty(), Iptv.S(src, "ua").NullIfEmpty());
            _checking = false;
            if (t != _token || !IsOpen) return;
            if (ph)
            {
                _ = SourceFailed("Kênh đang phát hình chờ (đoạn phim ngắn), chưa có luồng trực tiếp.", false, _token);
                return;
            }
        }
        _started = true;
        _startedAt = Util.NowMs();
        _listChecked = false;
        HideStatus();
        _ = Iptv.Played(Iptv.S(c, "k"));
        Log.D("tv", $"{Iptv.S(c, "n")} đang phát (nguồn {_source + 1})");
        SetControls(true);
    }

    private void ReopenLater(string why)
    {
        var c = _ch;
        if (c == null) return;
        Log.D("tv", $"luồng {Iptv.S(c, "n")} {why} — mở lại lần {_reopens + 1}");
        if (++_reopens > 5)
        {
            _ = SourceFailed("Luồng liên tục bị đứt.", false, _token);
            return;
        }
        // Bỏ luồng hỏng ngay (lỗi cũ không bị nhịp kiểm tra sau hiểu thành «không mở được»), chờ 1 giây rồi mở lại
        var t = ++_token;
        _started = false;
        _openedAt = Util.NowMs();
        _video?.Stop();
        ShowLoading("Đang nối lại…");
        _ = Task.Delay(1000).ContinueWith(_ => Dispatcher.BeginInvoke(() =>
        {
            if (t == _token && IsOpen) OpenSource();
        }));
    }

    private async Task SourceFailed(string reason, bool permanent, int t)
    {
        if (t != _token || !IsOpen) return;
        _video?.Stop();
        var c = _ch;
        if (c == null) return;
        var urls = Urls();
        var name = Iptv.S(c, "n");
        if (Iptv.AutoSource && _source + 1 < urls.Count)
        {
            Log.D("tv", $"{name} nguồn {_source + 1} lỗi ({reason}) — sang nguồn {_source + 2}");
            _source++;
            _reopens = 0;
            OpenSource();
            return;
        }
        var now = Iptv.NowSec();
        var match = Iptv.S(c, "match");
        var usable = urls.Any(u => Iptv.S(u, "bad") == "");
        if (usable && match is "later" or "soon" or "live")
        {
            // Trận sắp / đang đá mà chưa nguồn nào có hình: chờ rồi thử lại từ nguồn đầu (link thật hay được thêm sát giờ)
            var kick = Iptv.D(c, "kick");
            var msg = now < kick
                ? $"Trận chưa bắt đầu — bóng lăn lúc {Iptv.KickText(kick)}.\nKênh chưa lên sóng, tự thử lại sau 20 giây…"
                : "Trận đang đá nhưng kênh chưa phát hình.\nTự thử lại sau 20 giây…";
            Log.D("tv", $"{name} chưa có hình ({reason}) — chờ 20 s");
            ShowError(msg, true);
            _waitingRetry = true;
            await Task.Delay(20_000);
            if (t != _token || !IsOpen || _started) return;
            await RefreshThenRetry();
            return;
        }
        var text = $"{name} không phát được.\n{reason}";
        // Kênh thường hỏng hết nguồn: link có hạn dùng / người làm danh sách vừa thay link — tải lại danh sách (cũ quá 10 phút) một lần
        if (!permanent && !_listChecked && match == "none" && Iptv.S(Iptv.ActiveList(), "url") != "")
        {
            _listChecked = true;
            ShowLoading("Đang kiểm tra link mới…");
            if (await RefreshChannel(600)) RetryFromFirst();
            else if (t == _token) ShowError(text, true);
            return;
        }
        ShowError(text, !permanent);
    }

    /// Tải lại danh sách nếu cũ hơn age giây, lấy bản mới của kênh đang xem (cùng khoá). true = nguồn của kênh vừa đổi.
    private async Task<bool> RefreshChannel(int age)
    {
        var old = _ch;
        if (old == null) return false;
        try
        {
            await Iptv.RefreshIfOlder(age);
        }
        catch (Exception e)
        {
            Log.D("tv", "tải lại danh sách lỗi: " + e.Message);
        }
        var idx = await Iptv.IndexOf(_filter, Iptv.S(old, "k"));
        if (idx < 0) return false;
        var fresh = await Iptv.At(_filter, idx);
        if (fresh == null) return false;
        var before = string.Join("\n", Urls().Select(u => Iptv.S(u, "url")));
        _index = idx;
        _ch = fresh;
        var after = string.Join("\n", Urls().Select(u => Iptv.S(u, "url")));
        if (before != after) Log.D("tv", $"{Iptv.S(fresh, "n")} — danh sách vừa cập nhật nguồn");
        return before != after;
    }

    private async Task RefreshThenRetry()
    {
        await RefreshChannel(120);
        RetryFromFirst();
    }

    private void RetryFromFirst()
    {
        var urls = Urls();
        _source = 0;
        while (_source + 1 < urls.Count && Iptv.S(urls[_source], "bad") != "") _source++;
        _reopens = 0;
        OpenSource();
    }

    private async Task Retry()
    {
        var c = _ch;
        if (c == null) return;
        if (Iptv.B(c, "vod") && _statusText.Text.StartsWith("Đã xem hết"))
        {
            OpenSource();
            return;
        }
        ShowLoading("Đang kiểm tra link mới…");
        if (Iptv.D(c, "kick") > 0)
        {
            await RefreshThenRetry();
            return;
        }
        if (Iptv.S(Iptv.ActiveList(), "url") != "" && await RefreshChannel(600))
        {
            RetryFromFirst();
            return;
        }
        _reopens = 0;
        OpenSource();
    }

    // ---- Phát / dừng / trực tiếp ----

    private void TogglePlay()
    {
        if (_video == null) return;
        if (!_started)
        {
            _reopens = 0;
            OpenSource();
            return;
        }
        var st = _video.Read();
        var vod = Iptv.B(_ch, "vod");
        if (!st.Paused)
        {
            _video.Cmd("pause", null);
            _pausedAt = Util.NowMs();
        }
        else
        {
            // Đài radio tạm dừng: mở lại luồng (nghe đúng giờ phát, không phát phần đệm cũ)
            if (_radio && !vod)
            {
                OpenSource();
                return;
            }
            if (_pausedAt > 0 && !vod) _delay += (Util.NowMs() - _pausedAt) / 1000.0;
            _pausedAt = 0;
            _video.Cmd("play", null);
        }
        BumpHide();
    }

    /// Về trực tiếp: mở lại luồng (mép trực tiếp).
    private void GoLive()
    {
        _reopens = 0;
        OpenSource();
    }

    private void UpdateBadge(NativeVideo.State st)
    {
        var vod = Iptv.B(_ch, "vod");
        string text;
        var red = false;
        if (vod) text = !_started ? "PHIM" : st.Paused ? "TẠM DỪNG" : "▶ PHIM";
        else if (!_started) text = "CHƯA PHÁT";
        else if (st.Paused) text = "TẠM DỪNG";
        else if (_delay > 8) text = "CHẬM " + Util.FormatTime(_delay);
        else
        {
            text = "● TRỰC TIẾP";
            red = true;
        }
        _badge.Text = text;
        _badgeBox.Background = new SolidColorBrush(red ? Color.FromRgb(0xD9, 0x3A, 0x3F) : Color.FromRgb(0x5A, 0x60, 0x68));
        _btnLive.Visibility = _started && !vod && (_delay > 8 || st.Paused) ? Visibility.Visible : Visibility.Collapsed;
        _btnPlay.Content = _started && !st.Paused ? "Tạm dừng" : "Phát";
    }

    // ---- Nhãn ----

    private void UpdateLabels()
    {
        var c = _ch;
        if (c == null) return;
        _num.Text = Iptv.S(c, "num");
        var urls = Urls();
        _btnSource.Content = $"Nguồn {_source + 1}/{urls.Count}";
        _btnSource.Visibility = urls.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        _btnFav.Content = Iptv.B(c, "fav") ? "★" : "☆";
        _btnGuide.Visibility = (c["programmes"] as JsonArray)?.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _panelTitle.Text = $"{Iptv.S(Iptv.ActiveList(), "name")} · {_total} kênh";
        UpdateProgramme(_video?.Read());
        if (_radio) UpdateRadioCard();
    }

    private (JsonNode? Now, JsonNode? Next) Programmes()
    {
        var now = Iptv.NowSec();
        var all = _ch?["programmes"] as JsonArray;
        if (all == null) return (null, null);
        return (all.FirstOrDefault(p => Iptv.D(p, "s") <= now && now < Iptv.D(p, "e")), all.FirstOrDefault(p => Iptv.D(p, "s") > now));
    }

    private void UpdateProgramme(NativeVideo.State? st)
    {
        var c = _ch;
        if (c == null) return;
        var now = Iptv.NowSec();
        var (p, n) = Programmes();
        _title.Text = p != null ? $"{Iptv.S(c, "n")} · {Iptv.S(p, "t")}" : Iptv.S(c, "n");
        _prog.Text = p != null ? Iptv.S(p, "t") : Iptv.S(c, "n");
        double frac = -1;
        if (Iptv.B(c, "vod") && st is { D: > 0 } s && _started)
        {
            _time.Text = $"{Util.FormatTime(s.T)} / {Util.FormatTime(s.D)} · ◀ ▶ tua 10 giây";
            frac = s.T / s.D;
        }
        else if (p != null)
        {
            var e = Iptv.D(p, "e");
            _time.Text = $"{Iptv.Clock(Iptv.D(p, "s"))}–{Iptv.Clock(e)} · còn {Math.Max(1, Math.Ceiling((e - now) / 60)):0} phút";
            frac = (now - Iptv.D(p, "s")) / Math.Max(1, e - Iptv.D(p, "s"));
        }
        else if (Iptv.S(c, "matchLine") != "")
        {
            _time.Text = $"{Iptv.S(c, "g")} · {Iptv.S(c, "matchLine")}";
            if (Iptv.S(c, "match") == "live") frac = (now - Iptv.D(c, "kick")) / (Iptv.D(c, "dur") * 60);
        }
        else _time.Text = $"{Iptv.S(c, "g")}{(_radio ? " · 📻 radio" : "")} · chưa có lịch phát sóng";
        _next.Text = n != null ? $"Tiếp theo: {Iptv.Clock(Iptv.D(n, "s"))} {Iptv.S(n, "t")}" : "";
        _track.ColumnDefinitions.Clear();
        _track.Children.Clear();
        _track.Visibility = frac >= 0 ? Visibility.Visible : Visibility.Hidden;
        if (frac >= 0)
        {
            var f = Math.Clamp(frac, 0, 1);
            _track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(f, GridUnitType.Star) });
            _track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1 - f, GridUnitType.Star) });
            _track.Children.Add(new Border { Background = Ui.Res("Focus") });
        }
        if (!_started || _ticks % 15 == 0) _clock.Text = DateTime.Now.ToString("HH:mm");
    }

    // ---- Radio ----

    private void SetRadio(bool on)
    {
        if (_radio != on)
        {
            _radio = on;
            if (on) SetControls(true);
        }
        ShowStage();
        if (on) UpdateRadioCard();
    }

    private void UpdateRadioCard()
    {
        var c = _ch;
        if (c == null) return;
        _radioName.Text = Iptv.S(c, "n");
        var (p, _) = Programmes();
        _radioSong.Text = _icy != null ? "♪ " + _icy : p != null ? Iptv.S(p, "t") : "";
        _radioSong.Visibility = _radioSong.Text == "" ? Visibility.Collapsed : Visibility.Visible;
        _radioInfo.Text = _radioDesc != null ? "📻 Radio · " + _radioDesc : "📻 Radio";
        var logo = Iptv.S(c, "logo");
        if (logo != "" && ImageLoader.GetUrl(_radioLogo) != logo) ImageLoader.SetUrl(_radioLogo, logo);
        _radioLogo.Visibility = logo != "" ? Visibility.Visible : Visibility.Collapsed;
        _radioIcon.Visibility = logo == "" ? Visibility.Visible : Visibility.Collapsed;
    }

    /// Luồng không có hình (đài HLS như VOV, Icecast) → kiểu radio; có hình trở lại thì thôi. Tên bài ICY của đài.
    private void RadioTick()
    {
        if (_video == null || _ch == null) return;
        var info = _video.Info();
        var want = !info.HasVideo && !Iptv.B(_ch, "vod") && (Iptv.B(_ch, "radio") || Util.NowMs() - _startedAt > 4000);
        if (want != _radio)
        {
            Log.D("tv", $"{Iptv.S(_ch, "n")} {(want ? "chỉ có tiếng — hiện kiểu đài radio" : "có hình — thôi kiểu radio")}");
            SetRadio(want);
        }
        if (!_radio) return;
        var codec = info.AudioCodec?.ToUpperInvariant() switch
        {
            null => null,
            "MP3" or "MP3FLOAT" => "MP3",
            var x when x.StartsWith("AAC") => "AAC",
            var x => x,
        };
        var desc = string.Join(" · ", new[] { codec, info.Kbps > 0 ? $"{info.Kbps} kbps" : null }.Where(x => x != null));
        var icy = string.IsNullOrWhiteSpace(info.IcyTitle) ? null : info.IcyTitle.Trim();
        if (icy != _icy || desc != (_radioDesc ?? ""))
        {
            if (icy != null && icy != _icy) Log.D("tv", $"{Iptv.S(_ch, "n")} đang phát «{icy}»");
            _icy = icy;
            _radioDesc = desc == "" ? null : desc;
            UpdateRadioCard();
        }
    }

    // ---- Trạng thái ----

    private void ShowStage()
    {
        var statusOn = _status.Visibility == Visibility.Visible;
        _radioCard.Visibility = _radio && !statusOn ? Visibility.Visible : Visibility.Collapsed;
        // Cửa sổ của mpv che mọi thứ WPF trong khung: ẩn khi đang báo trạng thái / hiện thẻ đài
        _videoHost.Visibility = statusOn || _radio ? Visibility.Hidden : Visibility.Visible;
    }

    private void ShowLoading(string text)
    {
        _status.Visibility = Visibility.Visible;
        _spinner.Visibility = Visibility.Visible;
        _statusText.Text = text;
        _statusButtons.Visibility = Visibility.Collapsed;
        ShowStage();
    }

    private void ShowError(string text, bool retry, string retryLabel = "Thử lại")
    {
        Log.D("tv", text.Replace('\n', ' '));
        _status.Visibility = Visibility.Visible;
        _spinner.Visibility = Visibility.Collapsed;
        _statusText.Text = text;
        _statusButtons.Visibility = Visibility.Visible;
        _btnRetry.Visibility = retry ? Visibility.Visible : Visibility.Collapsed;
        _btnRetry.Content = retryLabel;
        ShowStage();
        SetControls(true, false);
        _hide.Stop();
        Dispatcher.BeginInvoke(() => (retry ? _btnRetry : _statusButtons.Children.OfType<Button>().Skip(1).First()).Focus(), DispatcherPriority.Loaded);
    }

    private void HideStatus()
    {
        _status.Visibility = Visibility.Collapsed;
        _statusButtons.Visibility = Visibility.Collapsed;
        ShowStage();
    }

    public void Notice(string text, int ms = 4000)
    {
        _notice.Text = "  " + text;
        _noticeOff.Stop();
        _noticeOff.Interval = TimeSpan.FromMilliseconds(ms);
        _noticeOff.Start();
    }

    // ---- Nút / bảng kênh ----

    private bool Controls => _bottom.Visibility == Visibility.Visible;

    private void SetControls(bool on, bool focus = true)
    {
        var was = Controls;
        _top.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        _bottom.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        if (on && focus && !was && _panel.Visibility != Visibility.Visible && _statusButtons.Visibility != Visibility.Visible)
            Dispatcher.BeginInvoke(() => _btnPlay.Focus(), DispatcherPriority.Loaded);
        BumpHide();
    }

    private void BumpHide()
    {
        _hide.Stop();
        _hide.Interval = TimeSpan.FromSeconds(_panel.Visibility == Visibility.Visible ? 10 : 6);
        if (Controls || _panel.Visibility == Visibility.Visible) _hide.Start();
    }

    /// Không bấm gì một lúc khi đang phát: ẩn nút và bảng kênh. Radio: không có hình để xem — giữ nút.
    private void AutoHide()
    {
        if (!_started || _video?.Read().Paused == true || _statusButtons.Visibility == Visibility.Visible) return;
        if (_panel.Visibility == Visibility.Visible) _panel.Visibility = Visibility.Collapsed;
        if (!_radio) SetControls(false);
    }

    private async Task TogglePanel()
    {
        if (_panel.Visibility == Visibility.Visible)
        {
            _panel.Visibility = Visibility.Collapsed;
            SetControls(true);
            _btnPlay.Focus();
            return;
        }
        _panel.Visibility = Visibility.Visible;
        await BuildPanel(true);
        BumpHide();
    }

    /// Bảng kênh: 100 kênh quanh kênh đang xem (danh sách lớn), ô đang xem tô màu.
    private async Task BuildPanel(bool focus)
    {
        var from = Math.Max(0, _index - 40);
        var page = await Iptv.Page(_filter, from, 100);
        _panelList.Children.Clear();
        var total = (int)Iptv.D(page, "total");
        _panelTitle.Text = $"{Iptv.S(Iptv.ActiveList(), "name")} · {total} kênh";
        if (from > 0) _panelList.Children.Add(Ui.Pill("▲ Kênh trước nữa", () => { _index = Math.Max(0, from - 60); _ = BuildPanel(true); }));
        Button? current = null;
        var i = from;
        foreach (var c in page["items"] as JsonArray ?? new JsonArray())
        {
            var idx = i++;
            var now = c!["now"] as JsonObject;
            var sub = Iptv.S(c, "bad") != "" ? "Máy này không phát được" : now != null ? Iptv.S(now, "t") : Iptv.S(c, "matchLine") is { Length: > 0 } ml ? ml
                : (Iptv.B(c, "radio") ? "📻 " : "") + Iptv.S(c, "g");
            var content = new StackPanel();
            content.Children.Add(Ui.Text($"{Iptv.S(c, "num")}   {Iptv.S(c, "n")}", 15, idx == _index ? Ui.Res("Brand") : null, FontWeights.SemiBold, false));
            content.Children.Add(Ui.Dim(sub, 12.5));
            var b = new Button { Content = content, HorizontalContentAlignment = HorizontalAlignment.Left, HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 0, 0, 3) };
            b.Click += (_, _) =>
            {
                if (idx != _index) _ = PlayAt(idx);
                BumpHide();
            };
            b.GotKeyboardFocus += (_, _) => BumpHide();
            if (idx == _index) current = b;
            _panelList.Children.Add(b);
        }
        if (from + 100 < total) _panelList.Children.Add(Ui.Pill("▼ Kênh sau nữa", () => { _index = Math.Min(total - 1, from + 140); _ = BuildPanel(true); }));
        if (current != null)
        {
            await Dispatcher.BeginInvoke(() =>
            {
                current.BringIntoView();
                if (focus) current.Focus();
            }, DispatcherPriority.Loaded);
        }
    }

    private void ToggleFavorite()
    {
        var c = _ch;
        if (c == null) return;
        var on = !Iptv.B(c, "fav");
        Iptv.SetFavorite(Iptv.S(c, "k"), on);
        c["fav"] = on;
        _btnFav.Content = on ? "★" : "☆";
        Notice(on ? $"Đã thêm {Iptv.S(c, "n")} vào Yêu thích." : $"Đã bỏ {Iptv.S(c, "n")} khỏi Yêu thích.");
        BumpHide();
    }

    private void OpenGuide()
    {
        var f = _filter;
        var i = _index;
        Close();
        _main.Push(new TvGuidePage(f, i));
    }

    // ---- Gõ số kênh ----

    private void TypeDigit(int d)
    {
        if (_digits.Length >= 5) _digits = "";
        _digits += d;
        Notice($"Kênh số {_digits}_", 1600);
        _digitsGo.Stop();
        _digitsGo.Start();
    }

    private async Task JumpToNumber()
    {
        var num = _digits.TrimStart('0');
        if (num == "") num = "0";
        _digits = "";
        var i = await Iptv.IndexOf(_filter, num: num);
        if (i >= 0) await PlayAt(i);
        else Notice($"Không có kênh số {num} trong danh sách đang xem.");
    }

    // ---- Giới hạn giờ xem ----

    private bool CheckLimit()
    {
        var b = WatchLimit.Blocked();
        if (b == null)
        {
            if (_started && !_limitWarned && WatchLimit.Remaining() is { } r and > 0 and <= 300)
            {
                _limitWarned = true;
                Notice($"Còn {WatchLimit.MinutesText(r)} xem hôm nay ({Prefs.CurrentProfile.Name}).", 8000);
            }
            return false;
        }
        var f = _filter;
        var i = _index;
        Close();
        _ = _main.LimitReached(b.Value, "", "", () => _main.PlayLive(f, i));
        return true;
    }

    /// Cổng gỡ lỗi: kênh, nguồn, đang phát, hình, radio, trạng thái.
    public string DebugStatus()
    {
        var st = _video?.Read();
        var info = _video?.Info();
        return $"kênh {Iptv.S(_ch, "num")} «{Iptv.S(_ch, "n")}» ({_index + 1}/{_total}) nguồn {_source + 1}/{Urls().Count} | " +
               $"{(_started ? "đang phát" : "chưa phát")} | {_badge.Text} | t={st?.T:0.0} d={st?.D:0.0} paused={st?.Paused} err={st?.Err} | " +
               $"hình {info?.Width}x{info?.Height} tiếng {info?.AudioCodec} {info?.Kbps}kbps | radio={_radio} «{_icy}» | " +
               $"trạng thái: {(_status.Visibility == Visibility.Visible ? _statusText.Text.Replace('\n', ' ') : "—")} | {_video?.Debug()}";
    }

    // ---- Phím ----

    public void HandleKey(KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        BumpHide();
        var vod = Iptv.B(_ch, "vod");
        switch (key)
        {
            case Key.PageUp or Key.MediaNextTrack:
                e.Handled = true;
                _ = Step(1);
                return;
            case Key.PageDown or Key.MediaPreviousTrack:
                e.Handled = true;
                _ = Step(-1);
                return;
            case Key.MediaPlayPause or Key.Space when Keyboard.FocusedElement is not TextBox:
                e.Handled = true;
                TogglePlay();
                return;
            case Key.G:
                e.Handled = true;
                if ((_ch?["programmes"] as JsonArray)?.Count > 0) OpenGuide();
                return;
            case Key.M or Key.Apps:
                e.Handled = true;
                _ = TogglePanel();
                return;
            case >= Key.D0 and <= Key.D9:
                e.Handled = true;
                TypeDigit(key - Key.D0);
                return;
            case >= Key.NumPad0 and <= Key.NumPad9:
                e.Handled = true;
                TypeDigit(key - Key.NumPad0);
                return;
            case Key.Escape or Key.BrowserBack or Key.Back:
                e.Handled = true;
                if (_panel.Visibility == Visibility.Visible) _ = TogglePanel();
                else if (Controls && _started) SetControls(false);
                else Close();
                return;
        }
        // Đang ẩn nút / bảng: phím mũi tên là lệnh của trình phát
        if (!Controls && _panel.Visibility != Visibility.Visible && _statusButtons.Visibility != Visibility.Visible)
        {
            e.Handled = true;
            switch (key)
            {
                case Key.Up:
                    _ = Step(-1);
                    break;
                case Key.Down:
                    _ = Step(1);
                    break;
                case Key.Left:
                    if (vod) Seek(-10);
                    else _ = TogglePanel();
                    break;
                case Key.Right:
                    if (vod) Seek(10);
                    else SetControls(true);
                    break;
                case Key.Enter:
                    SetControls(true);
                    break;
                default:
                    e.Handled = false;
                    break;
            }
            return;
        }
        // Nút / bảng đang hiện: đi giữa các nút
        if (KeyNav.DirOf(key) is { } dir)
        {
            e.Handled = true;
            var focused = Keyboard.FocusedElement as FrameworkElement;
            if (focused == null || !KeyNav.IsInside(focused, this))
            {
                if (KeyNav.First(this) is { } first) KeyNav.FocusAndShow(first);
                return;
            }
            var area = _panel.Visibility == Visibility.Visible && KeyNav.IsInside(focused, _panel) && dir is KeyNav.Dir.Up or KeyNav.Dir.Down ? (Visual)_panel : this;
            if (KeyNav.Next(area, focused, dir) is { } next) KeyNav.FocusAndShow(next);
        }
    }

    private void Seek(double by)
    {
        if (_video == null || !_started) return;
        var st = _video.Read();
        if (st.D <= 0) return;
        _video.Cmd("seekTo", Math.Clamp(st.T + by, 0, st.D));
        SetControls(true, false);
    }
}

internal static class LiveStrings
{
    public static string? NullIfEmpty(this string s) => s == "" ? null : s;
}
