using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.IO;

namespace CursorProfiles;

public partial class MainWindow : Window
{
    private readonly ProfileStore _store = new();
    private string _search = "";
    private int _sortMode; // 0 recent, 1 name, 2 size
    private int _filter; // 0 all, 1 active, 2 custom (non-built-in)
    private static readonly string[] SortLabels = { "Sort: Recent", "Sort: Name", "Sort: Size" };

    public MainWindow()
    {
        InitializeComponent();
        DarkTitleBar.Apply(this);
        var asm = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version;
        VersionPill.Text = asm is null ? "v1.0" : $"v{asm.Major}.{asm.Minor}.{asm.Build}";
        _store.Changed += Refilter;
        _store.StatsChanged += () => Dispatcher.Invoke(UpdateStats);
        _store.Error += msg => Dispatcher.Invoke(() =>
            MessageBox.Show(this, msg, "Prism", MessageBoxButton.OK, MessageBoxImage.Warning));
        _store.Info += msg => Dispatcher.Invoke(() =>
            MessageBox.Show(this, msg, "Shortcut Created", MessageBoxButton.OK, MessageBoxImage.Information));
        Refilter();
    }

    private void Refilter()
    {
        var list = _store.Profiles
            .Where(p => _search.Length == 0
                || p.Model.DisplayName.Contains(_search, StringComparison.OrdinalIgnoreCase)
                || p.Model.FolderName.Contains(_search, StringComparison.OrdinalIgnoreCase))
            .Where(p => _filter switch
            {
                1 => p.IsRunning,
                2 => !p.Model.IsSystem,
                _ => true,
            })
            .ToList();

        list.Sort((a, b) =>
        {
            if (a.Model.IsSystem != b.Model.IsSystem) return a.Model.IsSystem ? -1 : 1;
            if (a.Model.IsPinned != b.Model.IsPinned) return a.Model.IsPinned ? -1 : 1;
            return _sortMode switch
            {
                1 => string.Compare(a.Model.DisplayName, b.Model.DisplayName, StringComparison.OrdinalIgnoreCase),
                2 => (b.SizeBytes ?? 0).CompareTo(a.SizeBytes ?? 0),
                _ => (b.Model.LastLaunchedAt ?? DateTime.MinValue).CompareTo(a.Model.LastLaunchedAt ?? DateTime.MinValue),
            };
        });

        Cards.ItemsSource = list;
        EmptyState.Visibility = _store.Profiles.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        CursorMissingBanner.Visibility = _store.ResolvedCursorPath is null ? Visibility.Visible : Visibility.Collapsed;

        var active = _store.Profiles.Count(p => p.IsRunning);
        var custom = _store.Profiles.Count(p => !p.Model.IsSystem);
        FilterAllButton.Content = $"All ({_store.Profiles.Count})";
        FilterActiveButton.Content = $"Active ({active})";
        FilterCustomButton.Content = $"Custom ({custom})";
        StyleFilterTab(FilterAllButton, _filter == 0);
        StyleFilterTab(FilterActiveButton, _filter == 1);
        StyleFilterTab(FilterCustomButton, _filter == 2);
        DiskCountText.Text = $"{_store.Profiles.Count} profiles on disk";

        UpdateStatsTexts();
    }

    private void StyleFilterTab(Button button, bool selected)
    {
        button.FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal;
        button.Foreground = selected
            ? (System.Windows.Media.Brush)FindResource("TextBrush")
            : (System.Windows.Media.Brush)FindResource("SubTextBrush");
        button.Background = selected
            ? (System.Windows.Media.Brush)FindResource("FieldBrush")
            : System.Windows.Media.Brushes.Transparent;
    }

    /// <summary>Header badge + status bar. Real measured numbers only —
    /// called on every poll via StatsChanged, no list rebuild.</summary>
    private void UpdateStats()
    {
        UpdateStatsTexts();

        // Keep the Active tab membership truthful between polls.
        // (Refilter ends in UpdateStatsTexts, never back here — no loop.)
        if (_filter == 1) Refilter();
    }

    private void UpdateStatsTexts()
    {
        var running = _store.Profiles.Count(p => p.IsRunning);
        RunningBadge.Content = running > 0
            ? $"● {running} running · {Format.Bytes(_store.LiveBytesTotal)} live"
            : "Idle";
        CpuText.Text = _store.SystemCpuPercent is { } cpu ? $"{cpu:0}%" : "—";
        RamLiveText.Text = Format.Bytes(_store.LiveBytesTotal);
        RamTotalText.Text = _store.TotalPhysicalMemoryBytes > 0
            ? $"/ {Format.Bytes(_store.TotalPhysicalMemoryBytes)}" : "";
        ProfileCountText.Text = $"{_store.Profiles.Count} profiles";
    }

    private static ProfileVM? VmOf(object sender) => (sender as FrameworkElement)?.DataContext as ProfileVM;

    // MARK: Header actions

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        _search = SearchBox.Text.Trim();
        SearchHint.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Refilter();
    }

    private void SortButton_Click(object sender, RoutedEventArgs e)
    {
        _sortMode = (_sortMode + 1) % SortLabels.Length;
        SortButton.Content = SortLabels[_sortMode];
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

    private void Rescan_Click(object sender, RoutedEventArgs e) => _store.Reload();

    private void NewProfile_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ProfileEditorWindow(_store, null) { Owner = this };
        dialog.ShowDialog();
    }

    private void Settings_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new SettingsWindow(_store) { Owner = this };
        dialog.ShowDialog();
        Refilter();
    }

    // MARK: Card actions

    private void Launch_Click(object sender, RoutedEventArgs e)
    {
        // A running instance needs --new-window, otherwise this just
        // refocuses and looks dead.
        if (VmOf(sender) is { } vm) _store.Launch(vm, newWindow: vm.IsRunning);
    }

    private void Quit_Click(object sender, RoutedEventArgs e)
    {
        if (VmOf(sender) is { } vm) _store.Quit(vm);
    }

    private void Options_Click(object sender, RoutedEventArgs e)
    {
        if (VmOf(sender) is { } vm)
            new LaunchOptionsWindow(_store, vm) { Owner = this }.ShowDialog();
    }

    private void Shortcut_Click(object sender, RoutedEventArgs e)
    {
        if (VmOf(sender) is { } vm) _store.CreateOrUpdateShortcut(vm);
    }

    private void Card_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2 && VmOf(sender) is { } vm) _store.Launch(vm);
    }

    private void Card_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        if (sender is not Border border || VmOf(sender) is not { } vm) return;

        var menu = new ContextMenu();
        void Add(string header, Action action, bool enabled = true)
        {
            var item = new MenuItem { Header = header, IsEnabled = enabled };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }

        Add("Launch", () => _store.Launch(vm));
        Add("Launch with Options…", () =>
            new LaunchOptionsWindow(_store, vm) { Owner = this }.ShowDialog());
        if (vm.IsRunning) Add("Quit Profile", () => _store.Quit(vm));
        menu.Items.Add(new Separator());
        Add(vm.Model.IsPinned ? "Unpin" : "Pin to Top", () => { _store.TogglePin(vm); Refilter(); });
        Add("Edit…", () => new ProfileEditorWindow(_store, vm) { Owner = this }.ShowDialog());
        Add(vm.Model.IsSystem ? "Clone into New Profile" : "Duplicate",
            () => _store.Duplicate(vm), enabled: !vm.IsDuplicating);
        Add("Reveal in Explorer", () =>
            System.Diagnostics.Process.Start("explorer.exe", $"\"{_store.DirectoryFor(vm.Model)}\""));
        menu.Items.Add(new Separator());
        Add(_store.HasShortcut(vm) ? "Update Taskbar Shortcut" : "Create Taskbar Shortcut…",
            () => _store.CreateOrUpdateShortcut(vm));
        if (_store.HasShortcut(vm))
            Add("Remove Taskbar Shortcut", () => _store.RemoveShortcut(vm));
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

        border.ContextMenu = menu;
    }

    // MARK: Drag & drop a folder onto a card

    private void Card_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Link : DragDropEffects.None;
        e.Handled = true;
    }

    private void Card_Drop(object sender, DragEventArgs e)
    {
        if (VmOf(sender) is not { } vm) return;
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths || paths.Length == 0) return;
        var path = paths[0];
        if (Directory.Exists(path)) _store.Launch(vm, projectPath: path);
    }
}
