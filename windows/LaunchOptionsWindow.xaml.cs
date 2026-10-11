using System.Windows;

namespace CursorProfiles;

public partial class LaunchOptionsWindow : Window
{
    private readonly ProfileStore _store;
    private readonly ProfileVM _vm;

    public LaunchOptionsWindow(ProfileStore store, ProfileVM vm)
    {
        InitializeComponent();
        ThemeManager.ApplyChrome(this);
        _store = store;
        _vm = vm;
        TitleText.Text = $"Launch “{vm.Model.DisplayName}”";
        MemoryBox.Text = vm.Model.DefaultMemoryMB.ToString();
        ProjectBox.Text = vm.Model.DefaultProjectPath ?? "";
        // Memory cap is Cursor-only; project folder is unused by Desktop.
        var isCursor = vm.Model.NormalizedApp == CursorProfile.AppCursor;
        var isDesktop = vm.Model.NormalizedApp == CursorProfile.AppClaudeDesktop;
        MemoryBox.IsEnabled = isCursor;
        MemoryBox.Opacity = isCursor ? 1.0 : 0.45;
        ProjectBox.IsEnabled = !isDesktop;
        ProjectBox.Opacity = isDesktop ? 0.45 : 1.0;
    }

    private void ChooseFolder_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog();
        if (dialog.ShowDialog(this) == true) ProjectBox.Text = dialog.FolderName;
    }

    private void Launch_Click(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(MemoryBox.Text.Trim(), out var memory) || memory < 512)
            memory = _vm.Model.DefaultMemoryMB;
        var project = ProjectBox.Text.Trim();
        _store.Launch(_vm,
            projectPath: project.Length == 0 ? null : project,
            memoryMB: memory,
            newWindow: NewWindowBox.IsChecked == true);
        DialogResult = true;
    }
}
