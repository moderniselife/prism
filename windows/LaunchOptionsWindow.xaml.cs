using System.Windows;

namespace CursorProfiles;

public partial class LaunchOptionsWindow : Window
{
    private readonly ProfileStore _store;
    private readonly ProfileVM _vm;

    public LaunchOptionsWindow(ProfileStore store, ProfileVM vm)
    {
        InitializeComponent();
        DarkTitleBar.Apply(this);
        _store = store;
        _vm = vm;
        TitleText.Text = $"Launch “{vm.Model.DisplayName}”";
        MemoryBox.Text = vm.Model.DefaultMemoryMB.ToString();
        ProjectBox.Text = vm.Model.DefaultProjectPath ?? "";
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
