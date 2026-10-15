using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace CursorProfiles;

public partial class ProfileEditorWindow : Window
{
    private readonly ProfileStore _store;
    private readonly ProfileVM? _editing;   // null = create mode

    private string _colorHex = Palette.RandomHex();
    private readonly List<Border> _colorCells = new();

    public ProfileEditorWindow(ProfileStore store, ProfileVM? editing)
    {
        InitializeComponent();
        ThemeManager.ApplyChrome(this);
        _store = store;
        _editing = editing;

        if (editing is { } vm)
        {
            Title = "Edit Profile";
            SaveButton.Content = "Save";
            NameBox.Text = vm.Model.DisplayName;
            _colorHex = vm.Model.ColorHex;
            MemoryBox.Text = vm.Model.DefaultMemoryMB.ToString();
            ProjectBox.Text = vm.Model.DefaultProjectPath ?? "";
            SelectApp(vm.Model.NormalizedApp);
            AppBox.IsEnabled = false; // app is fixed after creation
            FooterNote.Text = vm.Model.IsSystem
                ? $"Built-in profile — {vm.Model.AppLabel} data"
                : $"Folder: {vm.Model.FolderName}";
        }
        else
        {
            Title = "New Profile";
            MemoryBox.Text = _store.Settings.DefaultMemoryMB.ToString();
        }

        BuildColorGrid();
        UpdatePreview();
    }

    private void SelectApp(string app)
    {
        foreach (ComboBoxItem item in AppBox.Items)
        {
            if ((string)item.Tag == app)
            {
                AppBox.SelectedItem = item;
                return;
            }
        }
        AppBox.SelectedIndex = 0;
    }

    private string SelectedApp =>
        (AppBox.SelectedItem as ComboBoxItem)?.Tag as string ?? CursorProfile.AppCursor;

    private void AppBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // Fires during InitializeComponent (SelectedIndex=0 applies before
        // sibling fields exist) — ignore those early events.
        if (AppBox is null || MemoryBox is null) return;
        // Memory cap only applies to Cursor; dim the field for Claude apps.
        var isCursor = SelectedApp == CursorProfile.AppCursor;
        MemoryBox.IsEnabled = isCursor;
        MemoryBox.Opacity = isCursor ? 1.0 : 0.45;
    }

    private void BuildColorGrid()
    {
        foreach (var (name, hex) in Palette.All)
        {
            var cell = new Border
            {
                Width = 26, Height = 26, CornerRadius = new CornerRadius(13),
                Margin = new Thickness(3), Cursor = System.Windows.Input.Cursors.Hand,
                Background = new SolidColorBrush(Palette.ColorFromHex(hex)),
                ToolTip = name, Tag = hex,
            };
            cell.MouseLeftButtonDown += (_, _) => { _colorHex = hex; UpdatePreview(); };
            _colorCells.Add(cell);
            ColorPanel.Children.Add(cell);
        }
    }

    private void UpdatePreview()
    {
        var c = Palette.ColorFromHex(_colorHex);
        var dim = Color.FromArgb(0xFF, (byte)(c.R * 0.72), (byte)(c.G * 0.72), (byte)(c.B * 0.72));
        PreviewHeader.Background = new LinearGradientBrush(c, dim, 35);
        var name = NameBox.Text.Trim();
        PreviewInitial.Text = name.Length == 0 ? "?" : name[..1].ToUpperInvariant();
        PreviewName.Text = string.IsNullOrWhiteSpace(NameBox.Text) ? "New Profile" : NameBox.Text;

        foreach (var cell in _colorCells)
        {
            var selected = (string)cell.Tag == _colorHex;
            cell.BorderBrush = selected ? Brushes.White : Brushes.Transparent;
            cell.BorderThickness = new Thickness(selected ? 2 : 0);
        }
    }

    private void NameBox_TextChanged(object sender, TextChangedEventArgs e) => UpdatePreview();

    private void ChooseFolder_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog();
        if (dialog.ShowDialog(this) == true) ProjectBox.Text = dialog.FolderName;
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        var name = NameBox.Text.Trim();
        if (name.Length == 0)
        {
            MessageBox.Show(this, "Give the profile a name.", "Prism",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        if (!int.TryParse(MemoryBox.Text.Trim(), out var memory) || memory < 512)
            memory = 16384;
        var project = ProjectBox.Text.Trim();

        if (_editing is { } vm)
        {
            var m = vm.Model.Copy();
            m.DisplayName = name;
            m.ColorHex = _colorHex;
            m.DefaultMemoryMB = memory;
            m.DefaultProjectPath = project.Length == 0 ? null : project;
            _store.Update(vm, m);
            DialogResult = true;
        }
        else
        {
            var created = _store.CreateProfile(name, SelectedApp, _colorHex, memory,
                project.Length == 0 ? null : project);
            if (created is not null) DialogResult = true;
        }
    }
}
