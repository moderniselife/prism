using System.Windows;

namespace CursorProfiles;

public partial class SettingsWindow : Window
{
    private readonly ProfileStore _store;

    public SettingsWindow(ProfileStore store)
    {
        InitializeComponent();
        DarkTitleBar.Apply(this);
        _store = store;
        DetectedPath.Text = store.ResolvedCursorPath ?? "Not found";
        CustomPathBox.Text = store.Settings.CustomCursorPath;
        MemoryBox.Text = store.Settings.DefaultMemoryMB.ToString();
        ProfilesDirText.Text = store.ProfilesDir;
    }

    private void Browse_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Filter = "Cursor|Cursor.exe|Executables|*.exe",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        };
        if (dialog.ShowDialog(this) == true) CustomPathBox.Text = dialog.FileName;
    }

    private void OpenProfiles_Click(object sender, RoutedEventArgs e) =>
        System.Diagnostics.Process.Start("explorer.exe", $"\"{_store.ProfilesDir}\"");

    private void Rescan_Click(object sender, RoutedEventArgs e) => _store.Reload();

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        _store.Settings.CustomCursorPath = CustomPathBox.Text.Trim();
        if (int.TryParse(MemoryBox.Text.Trim(), out var memory) && memory >= 512)
            _store.Settings.DefaultMemoryMB = memory;
        _store.Settings.Save(_store.ProfilesDir);
        DialogResult = true;
    }
}
