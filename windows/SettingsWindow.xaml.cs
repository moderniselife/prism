using System.Windows;
using System.Windows.Controls;

namespace CursorProfiles;

public partial class SettingsWindow : Window
{
    private readonly ProfileStore _store;

    public SettingsWindow(ProfileStore store)
    {
        InitializeComponent();
        ThemeManager.ApplyChrome(this);
        _store = store;
        DetectedPath.Text = store.ResolvedCursorPath ?? "Not found";
        CustomPathBox.Text = store.Settings.CustomCursorPath;
        DetectedCodePath.Text = store.ResolvedCodePath ?? "Not found";
        CustomCodePathBox.Text = store.Settings.CustomCodePath;
        DetectedDesktopPath.Text = store.ResolvedDesktopPath ?? "Not found";
        CustomDesktopPathBox.Text = store.Settings.CustomDesktopPath;
        SelectTheme(ThemeManager.NormalizeChoice(store.Settings.Theme));
        MemoryBox.Text = store.Settings.DefaultMemoryMB.ToString();
        ProfilesDirText.Text = store.ProfilesDir;
    }

    private void SelectTheme(string theme)
    {
        foreach (ComboBoxItem item in ThemeBox.Items)
        {
            if ((string)item.Tag == theme)
            {
                // Setting SelectedItem fires no user handler here; applied on Save.
                ThemeBox.SelectedItem = item;
                return;
            }
        }
        ThemeBox.SelectedIndex = 0;
    }

    private string SelectedTheme =>
        (ThemeBox.SelectedItem as ComboBoxItem)?.Tag as string ?? ThemeManager.System;

    private void Browse_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Filter = "Cursor|Cursor.exe|Executables|*.exe",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        };
        if (dialog.ShowDialog(this) == true) CustomPathBox.Text = dialog.FileName;
    }

    private void BrowseCode_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Filter = "Claude Code|claude.exe;claude.cmd|Executables|*.exe;*.cmd",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        };
        if (dialog.ShowDialog(this) == true) CustomCodePathBox.Text = dialog.FileName;
    }

    private void BrowseDesktop_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Filter = "Claude Desktop|Claude.exe;claude-desktop.exe|Executables|*.exe",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        };
        if (dialog.ShowDialog(this) == true) CustomDesktopPathBox.Text = dialog.FileName;
    }

    private void OpenProfiles_Click(object sender, RoutedEventArgs e) =>
        System.Diagnostics.Process.Start("explorer.exe", $"\"{_store.ProfilesDir}\"");

    private void Rescan_Click(object sender, RoutedEventArgs e) => _store.Reload();

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        _store.Settings.CustomCursorPath = CustomPathBox.Text.Trim();
        _store.Settings.CustomCodePath = CustomCodePathBox.Text.Trim();
        _store.Settings.CustomDesktopPath = CustomDesktopPathBox.Text.Trim();
        _store.Settings.Theme = SelectedTheme;
        if (int.TryParse(MemoryBox.Text.Trim(), out var memory) && memory >= 512)
            _store.Settings.DefaultMemoryMB = memory;
        _store.Settings.Save(_store.ProfilesDir);
        ThemeManager.ApplyTheme(_store.Settings.Theme);
        DialogResult = true;
    }
}
