using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CursorProfiles;

public partial class EndpointIdentityWindow : Window
{
    private static readonly string[] Colors = { "#3B82F6", "#22C55E", "#F59E0B", "#EF4444", "#EC4899", "#8B5CF6", "#14B8A6", "#64748B" };
    private static readonly string[] Actions = { "warn", "fallback", "block" };

    private readonly EndpointService _svc;
    private readonly EndpointIdentity _identity;
    private bool _isNew;
    private string _color;
    private string _token;
    private readonly List<CredRow> _rows = new();

    /// Shown in the endpoint window after saving.
    public string? Message { get; private set; }

    private sealed class CredRow
    {
        public EndpointCredential Credential = new();
        public ComboBox Provider = null!;
        public TextBox BaseUrl = null!;
        public PasswordBox Key = null!;
        public TextBlock Status = null!;
    }

    public EndpointIdentityWindow(EndpointService svc, EndpointIdentity identity, bool isNew)
    {
        InitializeComponent();
        _svc = svc;
        _identity = identity;
        _isNew = isNew;
        _color = identity.ColorHex;
        _token = identity.Token;

        TitleText.Text = isNew ? "New identity" : identity.Name;
        Title = TitleText.Text;
        NameBox.Text = identity.Name;
        DeleteButton.Visibility = isNew ? Visibility.Collapsed : Visibility.Visible;
        TokenText.Text = _token;

        ModelBox.Text = identity.DefaultModel;

        FallbackBox.Items.Add(new ComboBoxItem { Content = "Nothing (show the error)", Tag = null });
        foreach (var other in svc.Config.Identities.Where(i => i.Id != identity.Id))
            FallbackBox.Items.Add(new ComboBoxItem { Content = other.Name, Tag = other.Id });
        FallbackBox.SelectedIndex = Math.Max(0, FallbackBox.Items.Cast<ComboBoxItem>().ToList()
            .FindIndex(i => (string?)i.Tag == identity.FallbackIdentityId));

        BudgetBox.Text = identity.MonthlyBudget is double b && b > 0 ? b.ToString("0.##") : "";
        BudgetActionBox.SelectedIndex = Math.Max(0, Array.IndexOf(Actions, identity.BudgetAction));

        foreach (var c in identity.Credentials)
            AddRow(new EndpointCredential { Id = c.Id, Provider = c.Provider, BaseUrl = c.BaseUrl });
        RenderColors();
        UpdateSlug();
        _ = LoadModels();
    }

    // MARK: Name and colour

    private void Name_Changed(object sender, TextChangedEventArgs e) => UpdateSlug();

    private void UpdateSlug()
    {
        if (SlugText == null) return;
        var slug = EndpointConfig.Slugify(NameBox.Text);
        SlugText.Text = slug.Length == 0 ? "" : $"Type @{slug} in a chat, or use the model prefix {slug}/…";
    }

    private void RenderColors()
    {
        ColorPicker.Children.Clear();
        foreach (var hex in Colors)
        {
            var dot = new Ellipse
            {
                Width = 16, Height = 16, Margin = new Thickness(3, 0, 0, 0),
                Fill = EndpointWindow.HexBrush(hex), Cursor = System.Windows.Input.Cursors.Hand,
                StrokeThickness = string.Equals(hex, _color, StringComparison.OrdinalIgnoreCase) ? 2 : 0,
            };
            dot.SetResourceReference(Shape.StrokeProperty, "TextBrush");
            dot.MouseLeftButtonUp += (_, _) => { _color = hex; RenderColors(); };
            ColorPicker.Children.Add(dot);
        }
    }

    // MARK: Credentials

    private void AddProvider_Click(object sender, RoutedEventArgs e)
    {
        var used = _rows.Select(r => r.Credential.Provider).ToHashSet();
        var next = EndpointCredential.Providers.FirstOrDefault(p => !used.Contains(p)) ?? "compatible";
        AddRow(new EndpointCredential { Provider = next });
    }

    private void AddRow(EndpointCredential cred)
    {
        var row = new CredRow { Credential = cred };
        var panel = new StackPanel { Margin = new Thickness(0, 8, 0, 8) };
        if (_rows.Count > 0)
        {
            var div = new Border { Height = 1, Margin = new Thickness(0, -8, 0, 8) };
            div.SetResourceReference(Border.BackgroundProperty, "SubtleBorderBrush");
            panel.Children.Add(div);
        }

        var top = new DockPanel();
        var remove = new Button { Content = "Remove", Margin = new Thickness(6, 0, 0, 0) };
        remove.SetResourceReference(StyleProperty, "QuietButton");
        DockPanel.SetDock(remove, Dock.Right);
        var check = new Button { Content = "Check", Margin = new Thickness(6, 0, 0, 0), ToolTip = "Save and list the models this key can use" };
        check.SetResourceReference(StyleProperty, "QuietButton");
        DockPanel.SetDock(check, Dock.Right);
        top.Children.Add(remove);
        top.Children.Add(check);

        row.Provider = new ComboBox { Width = 160, Margin = new Thickness(0, 0, 8, 0) };
        row.Provider.SetResourceReference(StyleProperty, "ThemeComboBox");
        foreach (var p in EndpointCredential.Providers) row.Provider.Items.Add(new ComboBoxItem { Content = EndpointCredential.Label(p) });
        row.Provider.SelectedIndex = Math.Max(0, Array.IndexOf(EndpointCredential.Providers, cred.Provider));
        DockPanel.SetDock(row.Provider, Dock.Left);
        top.Children.Add(row.Provider);

        row.Key = new PasswordBox { VerticalContentAlignment = VerticalAlignment.Center, ToolTip = "API key (blank keeps the saved key)" };
        row.Key.SetResourceReference(StyleProperty, "DarkPasswordField");
        top.Children.Add(row.Key);
        panel.Children.Add(top);

        row.BaseUrl = new TextBox { Margin = new Thickness(0, 8, 0, 0), Text = cred.BaseUrl, ToolTip = "Base URL, e.g. http://localhost:8080/v1 for a local server" };
        row.BaseUrl.SetResourceReference(StyleProperty, "DarkField");
        panel.Children.Add(row.BaseUrl);

        row.Status = new TextBlock { FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        row.Status.SetResourceReference(TextBlock.ForegroundProperty, "MutedBrush");
        panel.Children.Add(row.Status);

        void UpdateKind()
        {
            var p = EndpointCredential.Providers[Math.Max(0, row.Provider.SelectedIndex)];
            row.Credential.Provider = p;
            row.BaseUrl.Visibility = p == "compatible" ? Visibility.Visible : Visibility.Collapsed;
            row.Key.ToolTip = p == "compatible" ? "API key, if the server needs one" : "API key (blank keeps the saved key)";
        }
        row.Provider.SelectionChanged += (_, _) => UpdateKind();
        UpdateKind();

        remove.Click += (_, _) =>
        {
            _rows.Remove(row);
            CredentialList.Children.Remove(panel);
        };
        check.Click += async (_, _) => await Check(row);

        _rows.Add(row);
        CredentialList.Children.Add(panel);
    }

    private async Task Check(CredRow row)
    {
        row.Status.Text = "Checking…";
        var err = await Commit();
        if (err != null) { row.Status.Text = err; return; }
        if (await _svc.StatusAsync() == null)
        {
            row.Status.Text = "Saved. Start the endpoint to check the key.";
            return;
        }
        var (error, models) = await _svc.CheckAsync(row.Credential.Id);
        if (error != null)
        {
            row.Status.Text = error;
            row.Status.SetResourceReference(TextBlock.ForegroundProperty, "DangerBrush");
            return;
        }
        row.Status.SetResourceReference(TextBlock.ForegroundProperty, "SuccessBrush");
        row.Status.Text = models.Count == 0 ? "Works." : $"Works · {models.Count} models: {string.Join(", ", models.Take(4))}{(models.Count > 4 ? "…" : "")}";
        AddModels(models);
    }

    private async Task LoadModels()
    {
        var st = await _svc.StatusAsync();
        var models = st?.Identities.FirstOrDefault(i => i.Id == _identity.Id)?.Models;
        if (models != null) AddModels(models);
    }

    private void AddModels(IEnumerable<string> models)
    {
        var text = ModelBox.Text;
        foreach (var m in models)
            if (!ModelBox.Items.Cast<object>().Any(i => i.ToString() == m)) ModelBox.Items.Add(m);
        ModelBox.Text = text;
    }

    // MARK: Save

    /// Write the edits into the settings and keys. Returns an error, or null.
    private async Task<string?> Commit()
    {
        var name = NameBox.Text.Trim();
        if (name.Length == 0) return "Give the identity a name.";
        var slug = EndpointConfig.Slugify(name);
        if (_svc.Config.Identities.Any(i => i.Id != _identity.Id && i.Slug == slug))
            return $"Another identity is already called @{slug}.";
        double? budget = null;
        if (BudgetBox.Text.Trim().TrimStart('$') is { Length: > 0 } b)
        {
            if (!double.TryParse(b, System.Globalization.NumberStyles.Number, System.Globalization.CultureInfo.CurrentCulture, out var v) &&
                !double.TryParse(b, System.Globalization.NumberStyles.Number, System.Globalization.CultureInfo.InvariantCulture, out v) || v < 0)
                return "The budget should be a number of dollars.";
            budget = v > 0 ? v : null;
        }
        foreach (var r in _rows)
        {
            r.Credential.BaseUrl = r.BaseUrl.Text.Trim();
            if (r.Credential.Provider == "compatible" && r.Credential.BaseUrl.Length == 0)
                return "An OpenAI-compatible provider needs a base URL.";
        }

        _identity.Name = name;
        _identity.ColorHex = _color;
        _identity.DefaultModel = ModelBox.Text.Trim();
        _identity.Token = _token;
        _identity.FallbackIdentityId = (FallbackBox.SelectedItem as ComboBoxItem)?.Tag as string;
        _identity.MonthlyBudget = budget;
        _identity.BudgetAction = Actions[Math.Max(0, BudgetActionBox.SelectedIndex)];
        _identity.Credentials = _rows.Select(r => r.Credential).ToList();
        if (_isNew)
        {
            _svc.Config.Identities.Add(_identity);
            _svc.Config.ActiveIdentityId ??= _identity.Id;
            _isNew = false;
            DeleteButton.Visibility = Visibility.Visible;
        }
        _svc.Save();

        foreach (var r in _rows.Where(r => r.Key.Password.Length > 0))
        {
            var err = await _svc.SetKeyAsync(r.Credential.Id, r.Key.Password.Trim());
            if (err != null) return $"{r.Credential.ProviderLabel} key: {err}";
            r.Key.Clear();
            r.Status.Text = "Key saved.";
        }
        return null;
    }

    private async void Save_Click(object sender, RoutedEventArgs e)
    {
        var err = await Commit();
        if (err != null) { MessageText.Text = err; return; }
        Message = $"Saved {_identity.Name}.";
        DialogResult = true;
    }

    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this, $"Delete {_identity.Name}? Apps using its token stop working. Its saved keys stay in Credential Manager.",
                "Delete identity?", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        var cfg = _svc.Config;
        cfg.Identities.RemoveAll(i => i.Id == _identity.Id);
        cfg.Rules.RemoveAll(r => r.IdentityId == _identity.Id);
        foreach (var i in cfg.Identities.Where(i => i.FallbackIdentityId == _identity.Id)) i.FallbackIdentityId = null;
        if (cfg.ActiveIdentityId == _identity.Id) cfg.ActiveIdentityId = cfg.Identities.FirstOrDefault()?.Id;
        _svc.Save();
        Message = $"Deleted {_identity.Name}.";
        DialogResult = true;
    }

    private void CopyToken_Click(object sender, RoutedEventArgs e)
    {
        try { Clipboard.SetText(_token); MessageText.Text = "Token copied."; } catch { }
    }

    private void NewToken_Click(object sender, RoutedEventArgs e)
    {
        _token = EndpointConfig.NewToken();
        TokenText.Text = _token;
        MessageText.Text = "New token: Save to use it. Apps using the old one will stop working.";
    }
}
