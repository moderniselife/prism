using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace CursorProfiles;

public partial class EndpointWindow : Window
{
    private readonly EndpointService _svc = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(3) };
    private EndpointStatus? _status;
    private bool _busy;

    public EndpointWindow()
    {
        InitializeComponent();
        SnippetBox.SelectedIndex = 0;
        Render();
        _timer.Tick += async (_, _) => await RefreshStatus();
        Loaded += async (_, _) =>
        {
            await RefreshStatus();
            _timer.Start();
        };
        Closed += (_, _) => _timer.Stop();
    }

    private EndpointConfig Config => _svc.Config;

    private async Task RefreshStatus()
    {
        _status = await _svc.StatusAsync();
        RenderStatus();
        RenderIdentities();
        RenderLog();
    }

    private void Render()
    {
        PortBox.Text = Config.Port.ToString();
        AddressText.Text = _svc.BaseUrl + "/v1";
        TokenText.Text = Config.Token;
        LanBox.IsChecked = Config.AllowLan;
        TagsBox.IsChecked = Config.TagsEnabled;
        RenderStatus();
        RenderIdentities();
        RenderRules();
        RenderSnippetTokens();
        RenderSnippet();
        RenderLog();
    }

    // MARK: Server

    private void RenderStatus()
    {
        ServerButtons.Children.Clear();
        var helper = EndpointService.FindHelper();
        if (helper == null)
        {
            StatusText.Text = "The endpoint helper isn't installed";
            StatusDot.SetResourceReference(Shape.FillProperty, "MutedBrush");
            ServerButtons.Children.Add(MakeButton("Install", "PrimaryButton", async () => await Install()));
        }
        else if (_status != null)
        {
            StatusText.Text = $"Running · prism-endpoint {_status.Version}";
            StatusDot.SetResourceReference(Shape.FillProperty, "LiveBrush");
            ServerButtons.Children.Add(MakeButton("Stop", "SecondaryButton", async () =>
            {
                await _svc.StopAsync();
                await Task.Delay(400);
                await RefreshStatus();
            }));
        }
        else
        {
            StatusText.Text = Config.Enabled ? "Not running" : "Off";
            StatusDot.SetResourceReference(Shape.FillProperty, Config.Enabled ? "WarningBrush" : "MutedBrush");
            ServerButtons.Children.Add(MakeButton("Start", "PrimaryButton", async () => await Start()));
        }
        KeysHint.Visibility = _status?.KeysInFile == true ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task Install()
    {
        await Busy("Downloading the endpoint helper…", async () =>
        {
            var path = await EndpointService.InstallHelperAsync();
            Say("Installed " + path);
        });
        RenderStatus();
    }

    private async Task Start()
    {
        await Busy("Starting…", async () =>
        {
            var err = await _svc.StartAsync();
            Say(err ?? "Running. It keeps running after Prism closes; Stop turns it off.");
        });
        await RefreshStatus();
    }

    private void Port_LostFocus(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(PortBox.Text, out var port) || port < 1024 || port > 65535)
        {
            PortBox.Text = Config.Port.ToString();
            return;
        }
        if (port == Config.Port) return;
        Config.Port = port;
        _svc.Save();
        AddressText.Text = _svc.BaseUrl + "/v1";
        RenderSnippet();
        Say("Restart the endpoint to use the new port.");
    }

    private void Lan_Click(object sender, RoutedEventArgs e)
    {
        Config.AllowLan = LanBox.IsChecked == true;
        _svc.Save();
        Say("Restart the endpoint for this to take effect.");
    }

    private void Tags_Click(object sender, RoutedEventArgs e)
    {
        Config.TagsEnabled = TagsBox.IsChecked == true;
        _svc.Save();
    }

    private void CopyAddress_Click(object sender, RoutedEventArgs e) => Copy(_svc.BaseUrl + "/v1", "Address copied.");
    private void CopyToken_Click(object sender, RoutedEventArgs e) => Copy(Config.Token, "Token copied.");

    private void NewToken_Click(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this, "Apps using the current main token will stop working until you give them the new one.",
                "Make a new token?", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        Config.Token = EndpointConfig.NewToken();
        _svc.Save(); // the helper re-reads the settings within a few seconds
        TokenText.Text = Config.Token;
        RenderSnippet();
    }

    // MARK: Identities

    private void RenderIdentities()
    {
        IdentityList.Children.Clear();
        if (Config.Identities.Count == 0)
        {
            IdentityList.Children.Add(Muted("Add an identity for each account (Work, Personal…) with its API keys.", new Thickness(0, 10, 0, 10)));
            return;
        }
        var active = Config.Active;
        for (int i = 0; i < Config.Identities.Count; i++)
        {
            var id = Config.Identities[i];
            if (i > 0) IdentityList.Children.Add(Divider());
            var st = _status?.Identities.FirstOrDefault(s => s.Id == id.Id);

            var row = new DockPanel { Margin = new Thickness(0, 9, 0, 9) };
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(buttons, Dock.Right);
            if (id == active)
                buttons.Children.Add(new TextBlock { Text = "Active", FontSize = 11, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center, Foreground = Brush("AccentTextBrush") });
            else
                buttons.Children.Add(MakeButton("Use", "QuietButton", async () =>
                {
                    var err = await _svc.SetActiveAsync(id.Id);
                    if (err != null && _status != null) Say(err);
                    RenderIdentities();
                    RenderSnippet();
                }));
            buttons.Children.Add(MakeButton("Edit", "QuietButton", () => { EditIdentity(id); return Task.CompletedTask; }));
            row.Children.Add(buttons);

            var dot = new Ellipse { Width = 9, Height = 9, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center, Fill = HexBrush(id.ColorHex) };
            row.Children.Add(dot);

            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = id.Name, FontWeight = FontWeights.Medium });
            var providers = string.Join(", ", id.Credentials.Select(c =>
            {
                var label = c.ProviderLabel;
                if (st != null && st.Keys.TryGetValue(c.Id, out var has) && !has && c.KeyRequired) label += " (no key)";
                return label;
            }));
            var detail = $"@{id.Slug} · {(providers.Length > 0 ? providers : "no providers")}";
            text.Children.Add(Muted(detail));
            if (st != null)
            {
                var spend = $"${st.MonthCost:0.00} this month · {st.MonthRequests} requests";
                if (st.Budget > 0) spend += $" · budget ${st.Budget:0.##}";
                var line = Muted(spend);
                if (st.Budget > 0 && st.MonthCost >= st.Budget) line.SetResourceReference(TextBlock.ForegroundProperty, "DangerBrush");
                else if (st.Budget > 0 && st.MonthCost >= st.Budget * 0.8) line.SetResourceReference(TextBlock.ForegroundProperty, "WarningBrush");
                text.Children.Add(line);
                if (st.CooldownUntil is DateTime until && until > DateTime.UtcNow)
                {
                    var cd = Muted($"Rate-limited until {until.ToLocalTime():HH:mm}" +
                        (Config.Identity(id.FallbackIdentityId) is { } fb ? $": using {fb.Name}" : ""));
                    cd.SetResourceReference(TextBlock.ForegroundProperty, "WarningBrush");
                    text.Children.Add(cd);
                }
            }
            row.Children.Add(text);
            IdentityList.Children.Add(row);
        }
    }

    private void AddIdentity_Click(object sender, RoutedEventArgs e)
    {
        var colors = new[] { "#3B82F6", "#22C55E", "#F59E0B", "#EC4899", "#8B5CF6", "#14B8A6" };
        var id = new EndpointIdentity
        {
            Name = Config.Identities.Count switch { 0 => "Work", 1 => "Personal", _ => "Identity " + (Config.Identities.Count + 1) },
            ColorHex = colors[Config.Identities.Count % colors.Length],
            Credentials = { new EndpointCredential { Provider = "anthropic" } },
        };
        EditIdentity(id, isNew: true);
    }

    private void EditIdentity(EndpointIdentity identity, bool isNew = false)
    {
        var dialog = new EndpointIdentityWindow(_svc, identity, isNew) { Owner = this };
        if (dialog.ShowDialog() == true)
        {
            if (dialog.Message != null) Say(dialog.Message);
            Render();
            _ = RefreshStatus();
        }
    }

    // MARK: Rules

    private static readonly string[] RuleKinds = { "keyword", "regex", "client", "schedule" };

    private void RenderRules()
    {
        RuleList.Children.Clear();
        if (Config.Rules.Count == 0)
        {
            RuleList.Children.Add(Muted("Switch identity automatically when a message mentions a word, a request comes from a particular app, or at certain times.", new Thickness(0, 10, 0, 10)));
            return;
        }
        for (int i = 0; i < Config.Rules.Count; i++)
        {
            var rule = Config.Rules[i];
            if (i > 0) RuleList.Children.Add(Divider());
            var grid = new Grid { Margin = new Thickness(0, 8, 0, 8) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(170) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var on = new CheckBox { IsChecked = rule.Enabled, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0), ToolTip = "On" };
            on.Click += (_, _) => { rule.Enabled = on.IsChecked == true; _svc.Save(); };
            grid.Children.Add(on);

            var kind = Combo(RuleKinds.Select(EndpointRule.KindLabel), Array.IndexOf(RuleKinds, rule.Kind));
            Grid.SetColumn(kind, 1);
            kind.SelectionChanged += (_, _) =>
            {
                rule.Kind = RuleKinds[Math.Max(0, kind.SelectedIndex)];
                _svc.Save();
                RenderRules();
            };
            grid.Children.Add(kind);

            var pattern = new TextBox { Margin = new Thickness(8, 0, 8, 0), VerticalContentAlignment = VerticalAlignment.Center };
            pattern.SetResourceReference(StyleProperty, "DarkField");
            if (rule.Kind == "schedule")
            {
                pattern.Text = $"{Hm(rule.StartMinute)}-{Hm(rule.EndMinute)}";
                pattern.ToolTip = "Weekdays, from-to (24-hour), e.g. 09:00-17:00";
                pattern.LostFocus += (_, _) =>
                {
                    var parts = pattern.Text.Split('-', StringSplitOptions.TrimEntries);
                    if (parts.Length == 2 && Minutes(parts[0]) is int a && Minutes(parts[1]) is int b)
                    {
                        rule.StartMinute = a;
                        rule.EndMinute = b;
                        _svc.Save();
                    }
                    pattern.Text = $"{Hm(rule.StartMinute)}-{Hm(rule.EndMinute)}";
                };
            }
            else
            {
                pattern.Text = rule.Pattern;
                pattern.ToolTip = rule.Kind switch
                {
                    "keyword" => "Words or phrases, comma separated",
                    "regex" => "A regular expression matched against your messages",
                    _ => "Part of the app's name (User-Agent), e.g. claude-cli, codex, OpenWebUI",
                };
                pattern.LostFocus += (_, _) => { rule.Pattern = pattern.Text.Trim(); _svc.Save(); };
            }
            Grid.SetColumn(pattern, 2);
            grid.Children.Add(pattern);

            var target = Combo(Config.Identities.Select(x => "→ " + x.Name), Config.Identities.FindIndex(x => x.Id == rule.IdentityId));
            Grid.SetColumn(target, 3);
            target.SelectionChanged += (_, _) =>
            {
                if (target.SelectedIndex >= 0) { rule.IdentityId = Config.Identities[target.SelectedIndex].Id; _svc.Save(); }
            };
            grid.Children.Add(target);

            var remove = MakeButton("Remove", "QuietButton", () =>
            {
                Config.Rules.Remove(rule);
                _svc.Save();
                RenderRules();
                return Task.CompletedTask;
            });
            Grid.SetColumn(remove, 4);
            grid.Children.Add(remove);
            RuleList.Children.Add(grid);
        }
    }

    private void AddRule_Click(object sender, RoutedEventArgs e)
    {
        if (Config.Identities.Count == 0) { Say("Add an identity first."); return; }
        Config.Rules.Add(new EndpointRule { IdentityId = Config.Identities[0].Id });
        _svc.Save();
        RenderRules();
    }

    private static string Hm(int minutes) => $"{minutes / 60:00}:{minutes % 60:00}";

    private static int? Minutes(string s)
    {
        var p = s.Split(':');
        if (p.Length is 1 or 2 && int.TryParse(p[0], out var h) && h is >= 0 and <= 24)
        {
            var m = 0;
            if (p.Length == 2 && (!int.TryParse(p[1], out m) || m is < 0 or > 59)) return null;
            return Math.Min(h * 60 + m, 1440);
        }
        return null;
    }

    // MARK: Snippets

    private void RenderSnippetTokens()
    {
        var keep = SnippetTokenBox.SelectedIndex;
        SnippetTokenBox.Items.Clear();
        SnippetTokenBox.Items.Add(new ComboBoxItem { Content = "Main token (follows active)" });
        foreach (var id in Config.Identities)
            SnippetTokenBox.Items.Add(new ComboBoxItem { Content = "Always " + id.Name });
        SnippetTokenBox.SelectedIndex = keep > 0 && keep < SnippetTokenBox.Items.Count ? keep : 0;
    }

    private string SnippetToken =>
        SnippetTokenBox.SelectedIndex > 0 && SnippetTokenBox.SelectedIndex - 1 < Config.Identities.Count
            ? Config.Identities[SnippetTokenBox.SelectedIndex - 1].Token
            : Config.Token;

    private void SnippetChanged(object sender, SelectionChangedEventArgs e) => RenderSnippet();

    private void RenderSnippet()
    {
        if (SnippetText == null || SnippetTokenBox == null) return; // during InitializeComponent
        var token = SnippetToken;
        SnippetText.Text = SnippetBox.SelectedIndex switch
        {
            1 => _svc.ClaudeCode(token),
            2 => _svc.Codex(token),
            3 => _svc.ClaudeDesktop(token),
            _ => _svc.ChatApps(token),
        };
    }

    private void CopySnippet_Click(object sender, RoutedEventArgs e) => Copy(SnippetText.Text, "Copied.");

    // MARK: Log

    private void RenderLog()
    {
        LogList.Children.Clear();
        var log = _status?.Log ?? new();
        if (log.Count == 0)
        {
            LogList.Children.Add(Muted(_status == null ? "Start the endpoint to see requests here." : "No requests yet.", new Thickness(0, 6, 0, 6)));
            return;
        }
        foreach (var l in log.Take(30))
        {
            var row = new DockPanel { Margin = new Thickness(0, 4, 0, 4) };
            var right = new TextBlock { FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
            right.Text = $"{l.Date.ToLocalTime():HH:mm:ss}";
            right.SetResourceReference(TextBlock.ForegroundProperty, "MutedBrush");
            DockPanel.SetDock(right, Dock.Right);
            row.Children.Add(right);

            row.Children.Add(new Ellipse { Width = 7, Height = 7, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center, Fill = HexBrush(l.IdentityColor) });
            var text = new StackPanel();
            var head = new TextBlock { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
            head.Text = $"{l.Identity} · {l.Model} · {l.Status}";
            if (l.Status >= 400) head.SetResourceReference(TextBlock.ForegroundProperty, "DangerBrush");
            text.Children.Add(head);
            var parts = new List<string> { l.Client, l.Reason };
            if (l.InputTokens + l.OutputTokens > 0) parts.Add($"{l.InputTokens:N0} in / {l.OutputTokens:N0} out");
            if (l.Cost is double c) parts.Add($"${c:0.0000}");
            parts.Add($"{l.Milliseconds} ms");
            if (!string.IsNullOrEmpty(l.Note)) parts.Add(l.Note!);
            if (!string.IsNullOrEmpty(l.Error)) parts.Add(l.Error!);
            var sub = Muted(string.Join(" · ", parts.Where(p => !string.IsNullOrWhiteSpace(p))));
            sub.TextTrimming = TextTrimming.CharacterEllipsis;
            sub.ToolTip = sub.Text;
            text.Children.Add(sub);
            row.Children.Add(text);
            LogList.Children.Add(row);
        }
    }

    // MARK: Helpers

    private Button MakeButton(string label, string style, Func<Task> action)
    {
        var b = new Button { Content = label, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        b.SetResourceReference(StyleProperty, style);
        b.Click += async (_, _) =>
        {
            try { await action(); }
            catch (Exception ex) { Say(ex.Message); }
        };
        return b;
    }

    private ComboBox Combo(IEnumerable<string> items, int selected)
    {
        var c = new ComboBox { VerticalAlignment = VerticalAlignment.Center };
        c.SetResourceReference(StyleProperty, "ThemeComboBox");
        foreach (var i in items) c.Items.Add(new ComboBoxItem { Content = i });
        c.SelectedIndex = selected;
        return c;
    }

    private static TextBlock Muted(string text, Thickness? margin = null)
    {
        var t = new TextBlock { Text = text, FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = margin ?? new Thickness(0, 2, 0, 0) };
        t.SetResourceReference(TextBlock.ForegroundProperty, "MutedBrush");
        return t;
    }

    private static Border Divider()
    {
        var b = new Border { Height = 1 };
        b.SetResourceReference(Border.BackgroundProperty, "SubtleBorderBrush");
        return b;
    }

    private Brush Brush(string key) => (Brush)FindResource(key);

    internal static Brush HexBrush(string hex)
    {
        try { return new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex)); }
        catch { return Brushes.Gray; }
    }

    private void Copy(string text, string message)
    {
        try { Clipboard.SetText(text); Say(message); }
        catch { Say("Couldn't use the clipboard."); }
    }

    private void Say(string text) => MessageText.Text = text;

    private async Task Busy(string message, Func<Task> work)
    {
        if (_busy) return;
        _busy = true;
        BusyBar.Visibility = Visibility.Visible;
        Say(message);
        try { await work(); }
        catch (Exception ex) { Say(ex.Message); }
        finally
        {
            _busy = false;
            BusyBar.Visibility = Visibility.Collapsed;
        }
    }

    private void Done_Click(object sender, RoutedEventArgs e) => Close();
}
