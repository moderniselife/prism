using System.IO;
using System.Runtime.ExceptionServices;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using CursorProfiles;
using Xunit;

namespace Prism.Tests;

/// <summary>
/// Regression tests for the startup crash where TwoWay Run.Text bindings
/// targeted read-only ProfileVM properties. Run.Text binds TwoWay by
/// default in WPF (unlike TextBlock.Text), so every dynamic Run.Text
/// binding in the card template must be Mode=OneWay.
/// </summary>
public sealed class CardTemplateTests
{
    /// <summary>
    /// Realizes the REAL card DataTemplate headlessly (no visible window)
    /// for every app kind and both idle/running states, then forces layout —
    /// the same FrameworkTemplate + Measure path the crash stack showed.
    /// Pre-fix this throws InvalidOperationException on the first binding.
    /// </summary>
    [Fact]
    public void CardTemplate_Realizes_For_All_App_Kinds()
    {
        OnStaThread(() =>
        {
            var (winXaml, _) = LocateXaml();
            var resources = LoadAppResources();
            Assert.True(resources.Contains("BoolToVis"), "App.xaml resources failed to load");

            var window = (Window)XamlReader.Parse(Scrub(File.ReadAllText(winXaml)));
            foreach (var key in resources.Keys)
                window.Resources[key] = resources[key];

            var cards = (ItemsControl)window.FindName("Cards");
            Assert.NotNull(cards);
            var template = (DataTemplate)cards.ItemTemplate;
            Assert.NotNull(template);

            int realized = 0;
            foreach (var vm in SampleProfiles())
            {
                var root = (FrameworkElement)template.LoadContent();
                root.DataContext = vm;
                root.Measure(new Size(300, 300));
                root.Arrange(new Rect(new Size(300, 300)));
                root.UpdateLayout();
                realized++;
            }
            Assert.Equal(3, realized);
        });
    }

    /// <summary>
    /// Static guard for the pattern itself: no Run.Text binding in
    /// MainWindow.xaml may rely on the TwoWay default.
    /// </summary>
    [Fact]
    public void Run_Text_Bindings_Are_OneWay()
    {
        var (winXaml, _) = LocateXaml();
        var text = File.ReadAllText(winXaml);
        var offenders = Regex.Matches(text, @"<Run\b[^>]*Text=""\{Binding(?![^}]*Mode=OneWay)[^}]*\}""")
            .Select(m => m.Value.Trim())
            .ToList();
        Assert.True(offenders.Count == 0,
            "Run.Text binds TwoWay by default and must be Mode=OneWay:\n" + string.Join("\n", offenders));
    }

    private static readonly string[] ThemeBrushKeys =
    {
        "WindowBrush", "CardBrush", "CardBorderBrush", "CardHoverBorderBrush",
        "TextBrush", "SubTextBrush", "MutedBrush", "FieldBrush", "TrackBrush",
        "AccentBrush", "DangerBrush", "SuccessBrush",
    };

    /// <summary>
    /// Both theme dictionaries load and expose identical brush keys, so a
    /// theme switch can never blank the UI.
    /// </summary>
    [Fact]
    public void Theme_Dictionaries_Load_And_Match()
    {
        var (_, appXaml) = LocateXaml();
        var dir = Path.GetDirectoryName(appXaml)!;
        var dark = (ResourceDictionary)XamlReader.Parse(
            File.ReadAllText(Path.Combine(dir, "Themes", "Dark.xaml")));
        var light = (ResourceDictionary)XamlReader.Parse(
            File.ReadAllText(Path.Combine(dir, "Themes", "Light.xaml")));
        var darkKeys = dark.Keys.Cast<object>().Select(k => k.ToString()).ToHashSet();
        var lightKeys = light.Keys.Cast<object>().Select(k => k.ToString()).ToHashSet();
        Assert.Equal(darkKeys, lightKeys);
        foreach (var key in ThemeBrushKeys)
        {
            Assert.True(darkKeys.Contains(key), $"Dark.xaml missing {key}");
            Assert.IsType<System.Windows.Media.SolidColorBrush>(dark[key]);
            Assert.IsType<System.Windows.Media.SolidColorBrush>(light[key]);
        }
    }

    /// <summary>
    /// The card template realizes cleanly under both themes (catches
    /// DynamicResource misses and bad theme values, not just bindings).
    /// </summary>
    [Fact]
    public void CardTemplate_Realizes_Under_Both_Themes()
    {
        OnStaThread(() =>
        {
            var (winXaml, appXaml) = LocateXaml();
            var dir = Path.GetDirectoryName(appXaml)!;
            var resources = LoadAppResources();
            var window = (Window)XamlReader.Parse(Scrub(File.ReadAllText(winXaml)));
            // App styles (Card, buttons) + theme brushes, like the real app.
            foreach (var key in resources.Keys)
                window.Resources[key] = resources[key];
            var cards = (ItemsControl)window.FindName("Cards");
            var template = (DataTemplate)cards.ItemTemplate;
            foreach (var theme in new[] { "Dark.xaml", "Light.xaml" })
            {
                // Swap just the theme layer, mirroring ThemeManager.
                foreach (var key in ThemeBrushKeys)
                    window.Resources.Remove(key);
                var themeDict = (ResourceDictionary)XamlReader.Parse(
                    File.ReadAllText(Path.Combine(dir, "Themes", theme)));
                window.Resources.MergedDictionaries.Add(themeDict);
                foreach (var vm in SampleProfiles())
                {
                    var root = (FrameworkElement)template.LoadContent();
                    root.DataContext = vm;
                    root.Measure(new Size(300, 300));
                    root.Arrange(new Rect(new Size(300, 300)));
                    root.UpdateLayout();
                }
                window.Resources.MergedDictionaries.Clear();
            }
        });
    }

    /// <summary>
    /// ThemeManager must be safe headless (tests, designers): no
    /// Application, no window, no throw — and choice parsing is exact.
    /// </summary>
    [Fact]
    public void ThemeManager_Resolves_Choices()
    {
        OnStaThread(() =>
        {
            ThemeManager.ApplyTheme("dark");
            Assert.True(ThemeManager.IsDark);
            ThemeManager.ApplyTheme("light");
            Assert.False(ThemeManager.IsDark);
            ThemeManager.ApplyTheme("bogus-value");
            Assert.Equal(ThemeManager.SystemWantsDark(), ThemeManager.IsDark);
            ThemeManager.ApplyTheme(null);
            Assert.Equal(ThemeManager.SystemWantsDark(), ThemeManager.IsDark);
            Assert.Equal("dark", ThemeManager.NormalizeChoice("dark"));
            Assert.Equal("system", ThemeManager.NormalizeChoice("nope"));
        });
    }

    /// <summary>
    /// The Store alias is detected so isolated launches can be refused with
    /// guidance instead of silently opening the existing app; classic
    /// installs sort ahead of it in discovery.
    /// </summary>
    [Fact]
    public void DesktopCandidates_Prefer_Classic_Over_Store()
    {
        var candidates = ClaudeLauncher.DesktopCandidatePaths();
        Assert.True(candidates.Length >= 2);
        Assert.True(ClaudeLauncher.IsStoreAlias(candidates[^1]),
            "Store alias must be the last resort, got: " + candidates[^1]);
        foreach (var c in candidates[..^1])
            Assert.False(ClaudeLauncher.IsStoreAlias(c), "false Store positive: " + c);
        Assert.False(ClaudeLauncher.IsStoreAlias(null));
        Assert.False(ClaudeLauncher.IsStoreAlias(""));
        Assert.True(ClaudeLauncher.IsStoreAlias(
            @"C:\Users\u\AppData\Local\Microsoft\WindowsApps\claude-desktop.exe"));
        Assert.False(ClaudeLauncher.IsStoreAlias(
            @"C:\Users\u\AppData\Local\Programs\Claude\Claude.exe"));
    }

    /// <summary>
    /// Store builds hide command lines from WMI: the built-in Desktop is
    /// matched by package exe path, never by the claude-code helper.
    /// </summary>
    [Fact]
    public void SystemDesktopPids_Matches_Store_By_ExePath()
    {
        var list = new List<ProcessEntry>
        {
            // Store main instance: empty command line, package exe path.
            new(11, 100, "", @"C:\Program Files\WindowsApps\Claude_1.0_x64__abc\app\claude.exe"),
            // Bundled CLI helper: must never count as Desktop.
            new(12, 100, "", @"C:\Users\u\AppData\Roaming\Claude\claude-code\1.0\x\claude.exe"),
            // Classic main instance with a visible command line.
            new(13, 100, @"C:\Apps\Claude\Claude.exe"),
            // Renderer helper: excluded.
            new(14, 100, @"C:\Apps\Claude\Claude.exe --type=renderer"),
        };
        var pids = ClaudeLauncher.SystemDesktopPids(list);
        Assert.Contains(11, pids);
        Assert.DoesNotContain(12, pids);
        Assert.DoesNotContain(14, pids);
    }

    /// <summary>
    /// Managed Desktop profiles need the standalone build: a custom path
    /// pointing at the Store package must not count as one, and a missing
    /// install raises the typed exception the UI turns into an installer prompt.
    /// </summary>
    [Fact]
    public void FindClassicDesktop_Rejects_Store_Paths()
    {
        var store = Path.Combine(Path.GetTempPath(), "WindowsApps", "Claude", "Claude.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(store)!);
        File.WriteAllText(store, "");
        try
        {
            Assert.NotEqual(store, ClaudeLauncher.FindClassicDesktop(store));
        }
        finally { try { Directory.Delete(Path.Combine(Path.GetTempPath(), "WindowsApps"), true); } catch { } }
    }

    [Fact]
    public void DesktopPids_Matches_Equals_Form_Of_Flag()
    {
        var list = new List<ProcessEntry>
        {
            new(1, 0, @"C:\x\claude.exe --user-data-dir=C:\p\A", ""),
            new(2, 0, @"C:\x\claude.exe --type=renderer --user-data-dir=C:\p\A", ""),
            new(3, 0, @"C:\x\claude.exe --user-data-dir=C:\p\B", ""),
        };
        Assert.Equal(new[] { 1 }, ClaudeLauncher.DesktopPids(list, @"C:\p\A"));
    }

    /// <summary>
    /// The New-Profile editor must construct without showing: its app-picker
    /// SelectionChanged handler used to throw a NullReferenceException during
    /// InitializeComponent (sibling fields don't exist yet). Uses temp profile
    /// dirs so the real home directory is untouched.
    /// </summary>
    [Fact]
    public void ProfileEditorWindow_Constructs_In_Create_Mode()
    {
        OnStaThread(() =>
        {
            var store = NewTempStore();
            var dlg = new ProfileEditorWindow(store, null);
            dlg.Close();
        });
    }

    [Fact]
    public void ProfileEditorWindow_Constructs_In_Edit_Mode()
    {
        OnStaThread(() =>
        {
            var store = NewTempStore();
            var vm = new ProfileVM(new CursorProfile
            {
                FolderName = "Work",
                DisplayName = "Work",
                App = CursorProfile.AppClaudeCode,
                ColorHex = "#10B981",
                DefaultMemoryMB = 16384,
            });
            var dlg = new ProfileEditorWindow(store, vm);
            dlg.Close();
        });
    }

    [Fact]
    public void Settings_And_LaunchOptions_Windows_Construct()
    {
        OnStaThread(() =>
        {
            var store = NewTempStore();
            var vm = new ProfileVM(new CursorProfile
            {
                FolderName = "Desk",
                DisplayName = "Desk",
                App = CursorProfile.AppClaudeDesktop,
                ColorHex = "#3B82F6",
                DefaultMemoryMB = 16384,
            });
            new SettingsWindow(store).Close();
            new LaunchOptionsWindow(store, vm).Close();
        });
    }

    /// <summary>A store rooted at temp dirs: Reload/constructors never touch home.</summary>
    private static ProfileStore NewTempStore()
    {
        var root = Path.Combine(Path.GetTempPath(), "Prism.Tests", Guid.NewGuid().ToString("N"));
        return new ProfileStore(
            profilesDir: Path.Combine(root, "cursor"),
            codeDir: Path.Combine(root, "code"),
            desktopDir: Path.Combine(root, "desktop"));
    }

    private static ProfileVM[] SampleProfiles()
    {
        var cursor = new ProfileVM(new CursorProfile
        {
            FolderName = "Work",
            DisplayName = "Work",
            App = CursorProfile.AppCursor,
            ColorHex = "#6366F1",
            DefaultMemoryMB = 16384,
        });
        var code = new ProfileVM(new CursorProfile
        {
            FolderName = "CodeWork",
            DisplayName = "Code Work",
            App = CursorProfile.AppClaudeCode,
            ColorHex = "#10B981",
            DefaultMemoryMB = 16384,
        });
        // Sentinel PID (Store builds) exercises the no-PID display path.
        code.RunningPids = new List<int> { -1 };
        code.LiveBytes = 2048;
        var desktop = new ProfileVM(new CursorProfile
        {
            FolderName = CursorProfile.SystemDesktopFolderName,
            DisplayName = "Main Claude Desktop",
            App = CursorProfile.AppClaudeDesktop,
            ColorHex = "#3B82F6",
            IsPinned = true,
            IsSystem = true,
        });
        desktop.RunningPids = new List<int> { 1234 };
        desktop.LiveBytes = 1024 * 1024;
        return new[] { cursor, code, desktop };
    }

    /// <summary>Finds windows/MainWindow.xaml by walking up from the test bin dir.</summary>
    private static (string winXaml, string appXaml) LocateXaml()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (int i = 0; i < 8 && dir != null; i++, dir = dir.Parent)
        {
            var win = Path.Combine(dir.FullName, "windows", "MainWindow.xaml");
            var app = Path.Combine(dir.FullName, "windows", "App.xaml");
            if (File.Exists(win) && File.Exists(app))
                return (win, app);
        }
        throw new FileNotFoundException(
            "Could not locate windows/MainWindow.xaml from " + AppContext.BaseDirectory);
    }

    /// <summary>
    /// Loads App.xaml's resources WITHOUT instantiating an Application
    /// (only one may exist per AppDomain, and tests must stay independent):
    /// the inner Application.Resources block is parsed as a bare dictionary.
    /// </summary>
    private static ResourceDictionary LoadAppResources()
    {
        var (_, appXaml) = LocateXaml();
        var text = File.ReadAllText(appXaml);
        const string open = "<Application.Resources>";
        const string close = "</Application.Resources>";
        int start = text.IndexOf(open, StringComparison.Ordinal);
        int end = text.IndexOf(close, StringComparison.Ordinal);
        Assert.True(start >= 0 && end > start, "App.xaml has no Application.Resources block");
        var inner = text.Substring(start + open.Length, end - (start + open.Length));
        var wrapped = "<ResourceDictionary xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" "
            + "xmlns:x=\"http://schemas.microsoft.com/winfx/2006/xaml\">"
            + inner + "</ResourceDictionary>";
        return (ResourceDictionary)XamlReader.Parse(wrapped);
    }

    /// <summary>XamlReader has no code-behind: drop class hooks and event handlers.</summary>
    private static string Scrub(string xaml)
    {
        xaml = Regex.Replace(xaml, "\\sx:Class=\"[^\"]*\"", "");
        xaml = Regex.Replace(xaml, "\\sStartupUri=\"[^\"]*\"", "");
        xaml = Regex.Replace(xaml, "\\s(Click|TextChanged|ContextMenuOpening|MouseLeftButtonDown|Drop|DragOver|Checked|Unchecked|SelectionChanged|Toggled)=\"[^\"]*\"", "");
        return xaml;
    }

    /// <summary>
    /// One STA thread + one session Application for the whole run (WPF
    /// objects are thread-affine, and only one Application may exist per
    /// AppDomain). The session app carries the real App resources + theme,
    /// exactly like production startup, so compiled dialog BAML resolves.
    /// </summary>
    private static readonly Lazy<System.Windows.Threading.Dispatcher> StaDispatcher = new(() =>
    {
        System.Windows.Threading.Dispatcher? dispatcher = null;
        var ready = new ManualResetEventSlim();
        var thread = new Thread(() =>
        {
            dispatcher = System.Windows.Threading.Dispatcher.CurrentDispatcher;
            var app = new Application();
            var appResources = LoadAppResources();
            foreach (var key in appResources.Keys)
                app.Resources[key] = appResources[key];
            ThemeManager.ApplyTheme(ThemeManager.System);
            ready.Set();
            System.Windows.Threading.Dispatcher.Run();
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        ready.Wait();
        return dispatcher!;
    });

    /// <summary>xUnit runs MTA; all WPF work marshals to the session STA thread.</summary>
    private static void OnStaThread(Action action)
    {
        Exception? captured = null;
        StaDispatcher.Value.Invoke(() =>
        {
            try
            {
                action();
            }
            catch (Exception ex)
            {
                captured = ex;
            }
        });
        if (captured is not null)
            ExceptionDispatchInfo.Capture(captured).Throw();
    }
}
