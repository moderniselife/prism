using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CursorProfiles;

/// <summary>Create or edit a profile. New profiles choose Fresh account or
/// carry another profile's setup over (Overflow / Copy settings).</summary>
public partial class ProfileEditorWindow : Window
{
    private readonly ProfileStore _store;
    private readonly ProfileVM? _editing;   // null = create mode

    private string _app = CursorProfile.AppCursor;
    private string _colorHex = Palette.RandomHex();
    private bool _overflow;
    private readonly Dictionary<string, Button> _appTiles = new();
    private readonly List<Border> _colorCells = new();
    private readonly List<(Button Button, int MB)> _presets = new();

    public ProfileEditorWindow(ProfileStore store, ProfileVM? editing)
    {
        InitializeComponent();
        ThemeManager.ApplyChrome(this);
        _store = store;
        _editing = editing;

        BuildAppTiles();
        BuildColorGrid();
        BuildMemoryPresets();
        NameBox.TextChanged += (_, _) => NameHint.Visibility = NameBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

        if (editing is { } vm)
        {
            Title = HeaderTitle.Text = "Edit profile";
            SaveButton.Content = "Save";
            NameBox.Text = vm.Model.DisplayName;
            _colorHex = vm.Model.ColorHex;
            _app = vm.Model.NormalizedApp;
            MemoryBox.Text = vm.Model.DefaultMemoryMB.ToString();
            ProjectBox.Text = vm.Model.DefaultProjectPath ?? "";
            AppPanel.IsEnabled = false; // the app is fixed after creation
            AppPanel.Opacity = 0.6;
            AccountSection.Visibility = Visibility.Collapsed;
            FooterNote.Text = vm.Model.IsSystem
                ? $"Built-in profile: {vm.Model.AppLabel} data"
                : $"Folder: {vm.Model.FolderName}";
        }
        else
        {
            MemoryBox.Text = _store.Settings.DefaultMemoryMB.ToString();
        }
        UpdateAll();
    }

    private string? ProjectText => ProjectBox.Text.Trim() is { Length: > 0 } p ? p : null;

    // MARK: Building

    private static Viewbox LineIcon(Geometry data, double size, string brushKey)
    {
        var path = new Path
        {
            Data = data,
            StrokeThickness = 1.6,
            StrokeLineJoin = PenLineJoin.Round,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            Stretch = Stretch.None,
            Width = 20,
            Height = 20,
        };
        path.SetResourceReference(Shape.StrokeProperty, brushKey);
        return new Viewbox { Width = size, Height = size, Child = path };
    }

    private void BuildAppTiles()
    {
        foreach (var app in CursorProfile.AllApps)
        {
            var label = new TextBlock { Text = CursorProfile.LabelFor(app), FontSize = 12, Margin = new Thickness(0, 8, 0, 0),
                                        HorizontalAlignment = HorizontalAlignment.Center };
            var content = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            content.Children.Add(LineIcon(AppIcons.For(app), 18, "SubTextBrush"));
            content.Children.Add(label);
            var tile = new Button
            {
                Content = content,
                Style = (Style)FindResource("SecondaryButton"),
                Height = 72,
                Margin = new Thickness(app == CursorProfile.AppCursor ? 0 : 4, 0, app == CursorProfile.AppGrokBot ? 0 : 4, 0),
                Tag = app,
            };
            tile.Click += (_, _) => { _app = app; UpdateAll(); };
            _appTiles[app] = tile;
            AppPanel.Children.Add(tile);
        }
    }

    private void BuildColorGrid()
    {
        foreach (var (name, hex) in Palette.All)
        {
            var dot = new Ellipse { Width = 22, Height = 22, Fill = new SolidColorBrush(Palette.ColorFromHex(hex)) };
            var cell = new Border
            {
                Width = 30, Height = 30, CornerRadius = new CornerRadius(15),
                Margin = new Thickness(0, 0, 4, 4), Cursor = System.Windows.Input.Cursors.Hand,
                BorderThickness = new Thickness(2), Padding = new Thickness(2),
                Child = dot, ToolTip = name, Tag = hex, Background = Brushes.Transparent,
            };
            cell.MouseLeftButtonDown += (_, _) => { _colorHex = hex; UpdateAll(); };
            _colorCells.Add(cell);
            ColorPanel.Children.Add(cell);
        }
    }

    private void BuildMemoryPresets()
    {
        foreach (var (label, mb) in new[] { ("8 GB", 8192), ("16 GB", 16384), ("32 GB", 32768) })
        {
            var b = new Button { Content = label, Style = (Style)FindResource("QuietButton"), Width = 64, MinHeight = 26 };
            b.Click += (_, _) => { MemoryBox.Text = mb.ToString(); UpdateAll(); };
            _presets.Add((b, mb));
            MemoryPresets.Children.Add(b);
        }
    }

    // MARK: State → UI

    private List<ProfileVM> OverflowSources =>
        _store.Profiles.Where(p => p.Model.NormalizedApp == _app).ToList();

    private void UpdateAll()
    {
        foreach (var (app, tile) in _appTiles)
        {
            var selected = app == _app;
            tile.SetResourceReference(BackgroundProperty, selected ? "AccentSoftBrush" : "CardBrush");
            tile.SetResourceReference(BorderBrushProperty, selected ? "AccentBrush" : "CardBorderBrush");
            tile.BorderThickness = new Thickness(selected ? 1.5 : 1);
            tile.FontWeight = selected ? FontWeights.Medium : FontWeights.Normal;
        }
        foreach (var cell in _colorCells)
        {
            var selected = (string)cell.Tag == _colorHex;
            cell.BorderBrush = selected ? new SolidColorBrush(Palette.ColorFromHex(_colorHex)) : Brushes.Transparent;
        }

        var isCursor = _app == CursorProfile.AppCursor;
        MemorySection.Visibility = isCursor ? Visibility.Visible : Visibility.Collapsed;
        ProjectSection.Visibility = _app is CursorProfile.AppCursor or CursorProfile.AppClaudeCode
            ? Visibility.Visible : Visibility.Collapsed;
        ProjectHint.Visibility = ProjectBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        int.TryParse(MemoryBox.Text.Trim(), out var memory);
        foreach (var (button, mb) in _presets)
        {
            var selected = memory == mb;
            if (selected) button.SetResourceReference(BackgroundProperty, "CardBrush");
            else button.ClearValue(BackgroundProperty);
            button.SetResourceReference(ForegroundProperty, selected ? "TextBrush" : "SubTextBrush");
        }

        if (_editing is null) UpdateAccount();
    }

    private void UpdateAccount()
    {
        var isGrok = _app == CursorProfile.AppGrokBot;
        OverflowTitle.Text = CursorProfile.CopyChoiceLabelFor(_app);
        OverflowDetail.Text = isGrok
            ? "Copies local settings. Agents stay on your Grok account."
            : "Copies your setup, then you sign in with another account.";
        StyleOption(FreshOption, FreshDot, !_overflow);
        StyleOption(OverflowOption, OverflowDot, _overflow);
        OverflowDetails.Visibility = _overflow ? Visibility.Visible : Visibility.Collapsed;

        var sources = OverflowSources;
        var current = (SourceBox.SelectedItem as ComboBoxItem)?.Tag as ProfileVM;
        SourceBox.Items.Clear();
        foreach (var src in sources)
            SourceBox.Items.Add(new ComboBoxItem { Content = src.Model.DisplayName, Tag = src });
        var pick = sources.Contains(current!) ? current : sources.FirstOrDefault(s => s.Model.IsSystem) ?? sources.FirstOrDefault();
        foreach (ComboBoxItem item in SourceBox.Items)
            if (item.Tag == pick) SourceBox.SelectedItem = item;

        SourceRow.Visibility = sources.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (sources.Count == 0)
        {
            var label = CursorProfile.LabelFor(_app);
            OverflowExplainer.Text = $"No {label} profile to carry over from yet. Open {label} once, then come back.";
            OverflowExplainer.SetResourceReference(TextBlock.ForegroundProperty, "DangerBrush");
        }
        else
        {
            OverflowExplainer.Text = Explainer(_app);
            OverflowExplainer.SetResourceReference(TextBlock.ForegroundProperty, "MutedBrush");
        }
    }

    private static void StyleOption(Border option, Ellipse dot, bool selected)
    {
        option.SetResourceReference(Border.BackgroundProperty, selected ? "AccentSoftBrush" : "CardBrush");
        option.SetResourceReference(Border.BorderBrushProperty, selected ? "AccentBrush" : "CardBorderBrush");
        dot.SetResourceReference(Shape.StrokeProperty, selected ? "AccentBrush" : "MutedBrush");
        if (selected) dot.SetResourceReference(Shape.FillProperty, "AccentBrush");
        else dot.Fill = Brushes.Transparent;
    }

    /// <summary>What an overflow copies for each app: kept honest and specific.</summary>
    private static string Explainer(string app)
    {
        const string tail = " Sign in with your other account on first launch.";
        return CursorProfile.NormalizeApp(app) switch
        {
            CursorProfile.AppClaudeCode =>
                "Copies settings, CLAUDE.md, agents, commands, skills, output styles, hooks, plugins and your user-level MCP servers. Its login, account id and chat history stay behind." + tail,
            CursorProfile.AppClaudeDesktop =>
                "Copies the MCP config and installed extensions with their settings. Its login and cookies stay behind." + tail,
            CursorProfile.AppGrokBot =>
                "Copies local settings, permission choices and tool approvals only, not your agents, which live on your Grok Bot account. To bring an agent across: in the source profile open the agent → Create Template → Share a template link → Copy the share link, then paste that link into a chat in this profile." + tail,
            _ => "Copies settings, keybindings, tasks and snippets (extensions are already shared). Its login and machine id stay behind." + tail,
        };
    }

    // MARK: Events

    private void FreshOption_Click(object sender, System.Windows.Input.MouseButtonEventArgs e) { _overflow = false; UpdateAll(); }
    private void OverflowOption_Click(object sender, System.Windows.Input.MouseButtonEventArgs e) { _overflow = true; UpdateAll(); }

    private void MemoryBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_presets.Count > 0) UpdateAll(); // fires during InitializeComponent
    }

    private void ProjectBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (ProjectHint is not null) ProjectHint.Visibility = ProjectBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ChooseFolder_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog();
        if (dialog.ShowDialog(this) == true) ProjectBox.Text = dialog.FolderName;
    }

    private async void Save_Click(object sender, RoutedEventArgs e)
    {
        var name = NameBox.Text.Trim();
        if (name.Length == 0)
        {
            MessageBox.Show(this, "Give the profile a name.", "Prism", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        if (!int.TryParse(MemoryBox.Text.Trim(), out var memory) || memory < 512)
            memory = 16384;

        if (_editing is { } vm)
        {
            var m = vm.Model.Copy();
            m.DisplayName = name;
            m.ColorHex = _colorHex;
            m.DefaultMemoryMB = memory;
            m.DefaultProjectPath = ProjectText;
            _store.Update(vm, m);
            DialogResult = true;
            return;
        }

        if (_overflow)
        {
            if ((SourceBox.SelectedItem as ComboBoxItem)?.Tag is not ProfileVM source)
            {
                MessageBox.Show(this, "Choose a profile to copy from.", "Prism", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            SaveButton.IsEnabled = false;
            var created = await _store.CreateOverflow(name, _colorHex, memory, ProjectText, source);
            SaveButton.IsEnabled = true;
            if (created is not null) DialogResult = true;
            return;
        }

        if (_store.CreateProfile(name, _app, _colorHex, memory, ProjectText) is not null)
            DialogResult = true;
    }
}
