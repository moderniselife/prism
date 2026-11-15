using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace CursorProfiles;

/// <summary>
/// The hub: sidebar (search, filters, second brain, totals) | profile list
/// grouped into Running / Not running | detail panel for the selected
/// profile. The detail panel hides when the window is too narrow.
/// </summary>
public partial class MainWindow : Window
{
    private readonly ProfileStore _store = new();
    private string _search = "";
    private int _sortMode; // 0 recent, 1 name, 2 size
    private int _filter; // 0 all, 1 running, 2 custom, 3 cursor, 4 code, 5 desktop, 6 grok
    private static readonly string[] SortLabels = { "Recent ▾", "Name ▾", "Size ▾" };
    private static readonly string[] FilterTitles =
        { "All profiles", "Running", "Custom", "Cursor", "Claude Code", "Claude Desktop", "Grok Bot" };
    private const double InspectorMinWindowWidth = 1040;

    private ProfileVM? _selected;
    private HashSet<ProfileVM> _lastRunning = new();

    public MainWindow()
    {
        // Theme first so the first measure already uses the right palette.
        ThemeManager.ApplyTheme(_store.Settings.Theme);
        InitializeComponent();
        ThemeManager.ApplyChrome(this);

        _store.Changed += Refilter;
        _store.StatsChanged += () => Dispatcher.Invoke(UpdateStats);
        _store.Error += msg => Dispatcher.Invoke(() =>
            MessageBox.Show(this, msg, "Prism", MessageBoxButton.OK, MessageBoxImage.Warning));
        _store.DesktopInstallRequired += msg => Dispatcher.Invoke(() =>
        {
            var r = MessageBox.Show(this, msg + "\n\nOpen the download page now?",
                "Standalone Claude Desktop needed", MessageBoxButton.YesNo, MessageBoxImage.Information);
            if (r == MessageBoxResult.Yes) OpenDownloadPage();
        });
        _store.Info += msg => Dispatcher.Invoke(() =>
            MessageBox.Show(this, msg, "Shortcut Created", MessageBoxButton.OK, MessageBoxImage.Information));
        _store.Brain.PropertyChanged += Brain_PropertyChanged;

        SizeChanged += (_, _) => UpdateInspectorVisibility();
        PreviewKeyDown += Window_PreviewKeyDown;

        Refilter();
        UpdateBrainUi();
        _store.Brain.RefreshStatus();
    }

    // MARK: Filtering & grouping

    private bool Matches(ProfileVM p, int filter) => filter switch
    {
        1 => p.IsRunning,
        2 => !p.Model.IsSystem,
        3 => p.Model.NormalizedApp == CursorProfile.AppCursor,
        4 => p.Model.NormalizedApp == CursorProfile.AppClaudeCode,
        5 => p.Model.NormalizedApp == CursorProfile.AppClaudeDesktop,
        6 => p.Model.NormalizedApp == CursorProfile.AppGrokBot,
        _ => true,
    };

    private int Count(int filter) => _store.Profiles.Count(p => Matches(p, filter));

    private List<ProfileVM> Filtered()
    {
        var list = _store.Profiles
            .Where(p => Matches(p, _filter))
            .Where(p => _search.Length == 0
                || p.Model.DisplayName.Contains(_search, StringComparison.OrdinalIgnoreCase)
                || p.Model.FolderName.Contains(_search, StringComparison.OrdinalIgnoreCase)
                || p.Model.AppLabel.Contains(_search, StringComparison.OrdinalIgnoreCase)
                || p.Model.NormalizedApp.Contains(_search, StringComparison.OrdinalIgnoreCase))
            .ToList();

        list.Sort((a, b) =>
        {
            if (a.Model.IsPinned != b.Model.IsPinned) return a.Model.IsPinned ? -1 : 1;
            if (a.Model.IsSystem != b.Model.IsSystem) return a.Model.IsSystem ? -1 : 1;
            return _sortMode switch
            {
                1 => string.Compare(a.Model.DisplayName, b.Model.DisplayName, StringComparison.OrdinalIgnoreCase),
                2 => (b.SizeBytes ?? 0).CompareTo(a.SizeBytes ?? 0),
                _ => (b.Model.LastLaunchedAt ?? DateTime.MinValue).CompareTo(a.Model.LastLaunchedAt ?? DateTime.MinValue),
            };
        });
        return list;
    }

    private void Refilter()
    {
        var list = Filtered();
        var running = list.Where(p => p.IsRunning).ToList();
        var idle = list.Where(p => !p.IsRunning).ToList();
        _lastRunning = _store.Profiles.Where(p => p.IsRunning).ToHashSet();

        RunningRows.ItemsSource = running;
        IdleRows.ItemsSource = idle;
        RunningCount.Text = running.Count.ToString();
        IdleCount.Text = idle.Count.ToString();
        RunningSection.Visibility = running.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        IdleSection.Visibility = idle.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        var none = _store.Profiles.Count == 0;
        EmptyState.Visibility = none ? Visibility.Visible : Visibility.Collapsed;
        NoMatches.Visibility = !none && list.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ListScroll.Visibility = list.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ColumnHeader.Visibility = list.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (list.Count == 0 && !none)
        {
            NoMatchesText.Text = _search.Length > 0 ? $"No profiles match “{_search}”"
                : _filter == 1 ? "Nothing is running" : "Nothing here yet";
            NoMatchesButton.Content = _search.Length > 0 ? "Clear search" : "Show all profiles";
            NoMatchesButton.Visibility = _search.Length > 0 || _filter != 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        CursorMissingBanner.Visibility =
            _store.ResolvedCursorPath is null && Count(3) > 0 ? Visibility.Visible : Visibility.Collapsed;
        DesktopStoreBanner.Visibility = _store.NeedsStandaloneDesktop ? Visibility.Visible : Visibility.Collapsed;

        TitleText.Text = FilterTitles[_filter];
        TitleCount.Text = list.Count.ToString();
        CountAll.Text = Count(0).ToString();
        CountRunning.Text = Count(1).ToString();
        CountCustom.Text = Count(2).ToString();
        CountCursor.Text = Count(3).ToString();
        CountCode.Text = Count(4).ToString();
        CountDesktop.Text = Count(5).ToString();
        CountGrok.Text = Count(6).ToString();
        CountRunning.SetResourceReference(TextBlock.ForegroundProperty, Count(1) > 0 ? "SuccessBrush" : "MutedBrush");
        var nav = new[] { NavAll, NavRunning, NavCustom, NavCursor, NavCode, NavDesktop, NavGrok };
        for (int i = 0; i < nav.Length; i++) StyleNav(nav[i], i == _filter);

        // Keep the selection on screen; fall back to the first row listed.
        var shown = running.Concat(idle).ToList();
        if (_selected is null || !shown.Contains(_selected)) Select(shown.FirstOrDefault());
        else UpdateInspector();

        UpdateStatsTexts();
        UpdateInspectorVisibility();
    }

    private static void StyleNav(Button button, bool selected)
    {
        // Resource references (not frozen brushes) so live theme switches re-tint.
        button.SetResourceReference(ForegroundProperty, selected ? "TextBrush" : "SubTextBrush");
        if (selected) button.SetResourceReference(BackgroundProperty, "SelectedBrush");
        else button.ClearValue(BackgroundProperty);
        button.FontWeight = selected ? FontWeights.Medium : FontWeights.Normal;
    }

    /// <summary>Every poll: totals and the running group stay truthful
    /// without rebuilding the list unless membership changed.</summary>
    private void UpdateStats()
    {
        var running = _store.Profiles.Where(p => p.IsRunning).ToHashSet();
        if (!running.SetEquals(_lastRunning)) Refilter();
        else UpdateStatsTexts();
    }

    private void UpdateStatsTexts()
    {
        var running = _store.Profiles.Count(p => p.IsRunning);
        RunningSummary.Text = running > 0
            ? $"{running} running · {Format.Bytes(_store.LiveBytesTotal)}"
            : "Nothing running";
        var cpu = _store.SystemCpuPercent is { } c ? $"{c:0}%" : "—";
        SystemSummary.Text = _store.TotalPhysicalMemoryBytes > 0
            ? $"CPU {cpu} · {Format.Bytes(_store.TotalPhysicalMemoryBytes)} RAM"
            : $"CPU {cpu}";
    }

    // MARK: Selection & detail panel

    private void Select(ProfileVM? vm)
    {
        if (_selected is not null) _selected.IsSelected = false;
        _selected = vm;
        if (vm is not null) vm.IsSelected = true;
        UpdateInspector();
    }

    private void UpdateInspectorVisibility()
    {
        var show = ActualWidth >= InspectorMinWindowWidth && _selected is not null;
        Inspector.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        InspectorColumn.Width = show ? new GridLength(320) : new GridLength(0);
    }

    private void UpdateInspector()
    {
        InspectorContent.DataContext = _selected;
        UpdateInspectorVisibility();
        if (_selected is not { } vm) return;
        DataPathText.Text = vm.Model.IsSystem ? "Default location" : BrainService.Tilde(_store.DirectoryFor(vm.Model));
        DataPathText.ToolTip = _store.DirectoryFor(vm.Model);
        ShortcutText.Text = _store.HasShortcut(vm) ? "Update taskbar shortcut" : "Create taskbar shortcut";
        UpdateBrainUi();
    }

    private void Brain_PropertyChanged(object? sender, PropertyChangedEventArgs e) =>
        Dispatcher.Invoke(UpdateBrainUi);

    private void UpdateBrainUi()
    {
        var brain = _store.Brain;
        BrainState.Text = brain.IsOn ? "On" : "Off";
        BrainDot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, brain.IsOn ? "LiveBrush" : "MutedBrush");
        BrainDetail.Text = brain.CardDetail;

        if (_selected is not { } vm) return;
        if (vm.IsGrok)
        {
            BrainBlurb.Text = "Grok agents run in the cloud. Paste the Brainium snippet into an agent's instructions to share memory with your other apps.";
            BrainAction.Content = "Copy snippet";
        }
        else if (brain.IsOn)
        {
            BrainBlurb.Text = "Connect this profile so its agents read and write the same memory as your other apps.";
            BrainAction.Content = "Connect this profile";
        }
        else
        {
            BrainBlurb.Text = "Set up Brainium to give every profile one shared memory.";
            BrainAction.Content = "Set up…";
        }
        BrainAction.IsEnabled = !brain.Busy;
        BrainMessage.Text = brain.Message ?? "";
        BrainMessage.Visibility = string.IsNullOrEmpty(brain.Message) ? Visibility.Collapsed : Visibility.Visible;
    }

    private void InspectorLaunch_Click(object sender, RoutedEventArgs e)
    {
        if (_selected is { } vm) _store.Launch(vm, newWindow: vm.IsRunning);
    }

    private void InspectorSecondary_Click(object sender, RoutedEventArgs e)
    {
        if (_selected is not { } vm) return;
        if (vm.IsRunning) _store.Quit(vm);
        else new LaunchOptionsWindow(_store, vm) { Owner = this }.ShowDialog();
    }

    private void InspectorMore_Click(object sender, RoutedEventArgs e)
    {
        if (_selected is not { } vm) return;
        var menu = BuildMenu(vm);
        menu.PlacementTarget = InspectorMore;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        menu.IsOpen = true;
    }

    private async void CopyToNew_Click(object sender, RoutedEventArgs e)
    {
        if (_selected is not { } vm || vm.IsDuplicating) return;
        if (vm.Model.ClonesWholeProfile) await _store.NewOverflow(vm);
        else _store.Duplicate(vm);
    }

    private void ShowFolder_Click(object sender, RoutedEventArgs e)
    {
        if (_selected is { } vm) RevealInExplorer(vm);
    }

    private void Shortcut_Click(object sender, RoutedEventArgs e)
    {
        if (_selected is not { } vm) return;
        _store.CreateOrUpdateShortcut(vm);
        UpdateInspector();
    }

    private void BrainAction_Click(object sender, RoutedEventArgs e)
    {
        if (_selected is not { } vm) return;
        if (vm.IsGrok) _store.Brain.CopyGrokSnippet();
        else if (_store.Brain.IsOn) _store.Brain.WireProfile(vm);
        else OpenSecondBrain();
    }

    // MARK: Sidebar & header

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        _search = SearchBox.Text.Trim();
        SearchHint.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Refilter();
    }

    private void Filter_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string tag } && int.TryParse(tag, out var mode))
        {
            _filter = mode;
            Refilter();
        }
    }

    private void SortButton_Click(object sender, RoutedEventArgs e)
    {
        _sortMode = (_sortMode + 1) % SortLabels.Length;
        SortButton.Content = SortLabels[_sortMode];
        Refilter();
    }

    private void NoMatches_Click(object sender, RoutedEventArgs e)
    {
        if (_search.Length > 0) SearchBox.Text = "";
        else { _filter = 0; Refilter(); }
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers != ModifierKeys.Control) return;
        if (e.Key == Key.K)
        {
            SearchBox.Focus();
            SearchBox.SelectAll();
            e.Handled = true;
        }
        else if (e.Key == Key.N)
        {
            NewProfile_Click(this, new RoutedEventArgs());
            e.Handled = true;
        }
    }

    private void NewProfile_Click(object sender, RoutedEventArgs e) =>
        new ProfileEditorWindow(_store, null) { Owner = this }.ShowDialog();

    private void Settings_Click(object sender, RoutedEventArgs e)
    {
        new SettingsWindow(_store) { Owner = this }.ShowDialog();
        Refilter();
    }

    private void BrainCard_Click(object sender, RoutedEventArgs e) => OpenSecondBrain();

    private void OpenSecondBrain()
    {
        new SecondBrainWindow(_store) { Owner = this }.ShowDialog();
        UpdateBrainUi();
    }

    private static void OpenDownloadPage()
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(ClaudeLauncher.DownloadUrl) { UseShellExecute = true }); }
        catch { /* no default browser */ }
    }

    private void InstallDesktop_Click(object sender, RoutedEventArgs e) => OpenDownloadPage();

    private void RevealInExplorer(ProfileVM vm) =>
        System.Diagnostics.Process.Start("explorer.exe", $"\"{_store.DirectoryFor(vm.Model)}\"");

    // MARK: Rows

    private static ProfileVM? VmOf(object sender) => (sender as FrameworkElement)?.DataContext as ProfileVM;

    private void Launch_Click(object sender, RoutedEventArgs e)
    {
        // A running instance needs --new-window, otherwise this just refocuses.
        if (VmOf(sender) is not { } vm) return;
        Select(vm);
        _store.Launch(vm, newWindow: vm.IsRunning);
    }

    private void Row_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (VmOf(sender) is not { } vm) return;
        Select(vm);
        if (e.ClickCount == 2) _store.Launch(vm, newWindow: vm.IsRunning);
    }

    private void Row_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        if (sender is not Border border || VmOf(sender) is not { } vm) return;
        Select(vm);
        border.ContextMenu = BuildMenu(vm);
    }

    private ContextMenu BuildMenu(ProfileVM vm)
    {
        var menu = new ContextMenu();
        void Add(string header, Action action, bool enabled = true)
        {
            var item = new MenuItem { Header = header, IsEnabled = enabled };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }

        Add(vm.LaunchLabel, () => _store.Launch(vm, newWindow: vm.IsRunning));
        Add("Launch with Options…", () => new LaunchOptionsWindow(_store, vm) { Owner = this }.ShowDialog());
        if (vm.IsRunning) Add("Quit", () => _store.Quit(vm));
        menu.Items.Add(new Separator());
        Add(vm.Model.IsPinned ? "Unpin" : "Pin to Top", () => { _store.TogglePin(vm); Refilter(); });
        Add("Edit…", () => new ProfileEditorWindow(_store, vm) { Owner = this }.ShowDialog());
        var duplicateTitle = !vm.Model.ClonesWholeProfile
            ? (vm.IsGrok ? "New Profile with These Settings" : "New Overflow Account from This")
            : vm.Model.IsSystem ? "Clone into New Profile" : "Duplicate";
        Add(duplicateTitle, () => _store.Duplicate(vm), enabled: !vm.IsDuplicating);
        if (vm.Model.ClonesWholeProfile)
            Add("New Overflow Account from This", () => _ = _store.NewOverflow(vm), enabled: !vm.IsDuplicating);
        Add("Show in Explorer", () => RevealInExplorer(vm));
        menu.Items.Add(new Separator());
        Add(_store.HasShortcut(vm) ? "Update Taskbar Shortcut" : "Create Taskbar Shortcut…",
            () => { _store.CreateOrUpdateShortcut(vm); UpdateInspector(); });
        if (_store.HasShortcut(vm))
            Add("Remove Taskbar Shortcut", () => { _store.RemoveShortcut(vm); UpdateInspector(); });
        if (!vm.Model.IsSystem)
        {
            menu.Items.Add(new Separator());
            Add("Move to Recycle Bin", () =>
            {
                var answer = MessageBox.Show(this,
                    $"Move “{vm.Model.DisplayName}” ({vm.SizeText}) to the Recycle Bin?\n\n" +
                    "All its settings, extensions and chat history go with it.",
                    "Delete Profile", MessageBoxButton.YesNo, MessageBoxImage.Warning);
                if (answer == MessageBoxResult.Yes) _store.Delete(vm);
            });
        }
        return menu;
    }

    private void Row_DragOver(object sender, DragEventArgs e)
    {
        var ok = e.Data.GetDataPresent(DataFormats.FileDrop) && VmOf(sender) is { Model.OpensProjectFolder: true };
        e.Effects = ok ? DragDropEffects.Link : DragDropEffects.None;
        e.Handled = true;
    }

    private void Row_Drop(object sender, DragEventArgs e)
    {
        if (VmOf(sender) is not { Model.OpensProjectFolder: true } vm) return;
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths || paths.Length == 0) return;
        if (Directory.Exists(paths[0])) _store.Launch(vm, projectPath: paths[0]);
    }
}
