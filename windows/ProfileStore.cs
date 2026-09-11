using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Threading;

namespace CursorProfiles;

/// <summary>Wraps a profile with live UI state (size, running, cloning).</summary>
public class ProfileVM : INotifyPropertyChanged
{
    public CursorProfile Model { get; private set; }

    public ProfileVM(CursorProfile model) => Model = model;

    private long? _sizeBytes;
    private List<int> _runningPids = new();
    private bool _isDuplicating;

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Raise([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public void Update(CursorProfile model)
    {
        Model = model;
        RaiseAll();
    }

    public void RaiseAll()
    {
        foreach (var p in new[] { nameof(DisplayName), nameof(Emoji), nameof(HeaderBrush),
                 nameof(AccentBrush), nameof(SizeText), nameof(LastLaunchedText), nameof(IsRunning),
                 nameof(IsSystem), nameof(ShowPin), nameof(ProjectText), nameof(HasProject),
                 nameof(RunningText), nameof(DotBrush), nameof(LaunchLabel), nameof(IsDuplicating) })
            Raise(p);
    }

    public long? SizeBytes
    {
        get => _sizeBytes;
        set { _sizeBytes = value; Raise(nameof(SizeText)); }
    }

    public List<int> RunningPids
    {
        get => _runningPids;
        set
        {
            _runningPids = value;
            Raise(nameof(IsRunning)); Raise(nameof(RunningText));
            Raise(nameof(DotBrush)); Raise(nameof(LaunchLabel));
        }
    }

    public bool IsDuplicating
    {
        get => _isDuplicating;
        set { _isDuplicating = value; Raise(); }
    }

    // Bindable projections
    public string DisplayName => Model.DisplayName;
    public string Emoji => Model.Emoji;
    public bool IsSystem => Model.IsSystem;
    public bool ShowPin => Model.IsPinned && !Model.IsSystem;
    public bool IsRunning => _runningPids.Count > 0;
    public string RunningText => IsRunning ? "Running" : "Idle";
    public string LaunchLabel => IsRunning ? "New Window" : "Launch";
    public string SizeText => Format.Bytes(_sizeBytes);
    public string LastLaunchedText => Format.Relative(Model.LastLaunchedAt);
    public string ProjectText => Model.DefaultProjectPath ?? "";
    public bool HasProject => !string.IsNullOrEmpty(Model.DefaultProjectPath);

    public Brush AccentBrush => new SolidColorBrush(Palette.ColorFromHex(Model.ColorHex));
    public Brush DotBrush => IsRunning
        ? new SolidColorBrush(Color.FromRgb(0x4A, 0xDE, 0x80))
        : new SolidColorBrush(Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF));

    public Brush HeaderBrush
    {
        get
        {
            var c = Palette.ColorFromHex(Model.ColorHex);
            var dim = Color.FromArgb(0xFF,
                (byte)(c.R * 0.72), (byte)(c.G * 0.72), (byte)(c.B * 0.72));
            return new LinearGradientBrush(c, dim, 35);
        }
    }
}

public class ProfileStore
{
    public string ProfilesDir { get; }
    public LauncherSettings Settings { get; }
    public List<ProfileVM> Profiles { get; } = new();

    public event Action? Changed;
    public event Action<string>? Error;
    public event Action<string>? Info;

    private const string MetadataName = ".profiles.json";
    private readonly DispatcherTimer _pollTimer;

    public static string SystemDataDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Cursor");

    public string? ResolvedCursorPath => CursorLauncher.FindCursor(
        string.IsNullOrWhiteSpace(Settings.CustomCursorPath) ? null : Settings.CustomCursorPath);

    public ProfileStore()
    {
        ProfilesDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".cursor_profiles");
        Settings = LauncherSettings.Load(ProfilesDir);
        Reload();

        _pollTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
        _pollTimer.Tick += (_, _) => RefreshRunning();
        _pollTimer.Start();
    }

    public string DirectoryFor(CursorProfile p) =>
        p.IsSystem ? SystemDataDir : Path.Combine(ProfilesDir, p.FolderName);

    // MARK: Loading

    public void Reload()
    {
        Directory.CreateDirectory(ProfilesDir);

        var known = LoadMetadata();

        var onDisk = Directory.EnumerateDirectories(ProfilesDir)
            .Select(Path.GetFileName)
            .Where(n => n is not null && !n.StartsWith('.'))
            .Cast<string>()
            .ToList();

        foreach (var name in onDisk)
        {
            if (known.Any(p => p.FolderName == name)) continue;
            var display = name.StartsWith("custom_") ? name["custom_".Length..] : name;
            known.Add(new CursorProfile
            {
                FolderName = name,
                DisplayName = display,
                ColorHex = Palette.RandomHex(),
            });
        }
        // Drop metadata for folders that no longer exist (never the built-in one).
        known.RemoveAll(p => !p.IsSystem && !onDisk.Contains(p.FolderName));

        // Surface the user's original Cursor profile — visible, launchable, protected.
        if (!known.Any(p => p.IsSystem) && Directory.Exists(SystemDataDir))
        {
            known.Insert(0, new CursorProfile
            {
                FolderName = CursorProfile.SystemFolderName,
                DisplayName = "Main Cursor",
                Emoji = "⭐",
                ColorHex = "#3B82F6",
                IsPinned = true,
                IsSystem = true,
            });
        }

        Profiles.Clear();
        foreach (var p in known) Profiles.Add(new ProfileVM(p));
        SaveMetadata();
        Changed?.Invoke();
        RefreshSizes();
        RefreshRunning();
    }

    private List<CursorProfile> LoadMetadata()
    {
        try
        {
            var path = Path.Combine(ProfilesDir, MetadataName);
            if (File.Exists(path))
                return JsonSerializer.Deserialize<List<CursorProfile>>(File.ReadAllText(path)) ?? new();
        }
        catch { /* corrupted metadata — rebuild from folders */ }
        return new();
    }

    public void SaveMetadata()
    {
        try
        {
            var json = JsonSerializer.Serialize(
                Profiles.Select(p => p.Model).ToList(),
                new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(Path.Combine(ProfilesDir, MetadataName), json);
        }
        catch (Exception e) { Error?.Invoke($"Could not save profile metadata: {e.Message}"); }
    }

    // MARK: CRUD

    public ProfileVM? CreateProfile(string displayName, string emoji, string colorHex,
                                    int memoryMB, string? projectPath)
    {
        var baseName = ProfileNaming.SanitizeFolderName(displayName.Replace(' ', '_'));
        if (baseName.Length == 0)
        {
            Error?.Invoke("Profile name must contain at least one letter, number, hyphen or underscore.");
            return null;
        }
        var folder = UniqueFolderName(baseName);

        var profile = new CursorProfile
        {
            FolderName = folder,
            DisplayName = displayName.Trim(),
            Emoji = emoji,
            ColorHex = colorHex,
            DefaultMemoryMB = memoryMB,
            DefaultProjectPath = string.IsNullOrWhiteSpace(projectPath) ? null : projectPath,
        };
        try { Directory.CreateDirectory(DirectoryFor(profile)); }
        catch (Exception e)
        {
            Error?.Invoke($"Could not create profile folder: {e.Message}");
            return null;
        }
        var vm = new ProfileVM(profile);
        Profiles.Add(vm);
        SaveMetadata();
        Changed?.Invoke();
        RefreshSizes();
        TitleBarColorizer.Apply(profile, DirectoryFor(profile));
        return vm;
    }

    private string UniqueFolderName(string baseName)
    {
        var folder = baseName;
        var counter = 2;
        while (folder == CursorProfile.SystemFolderName ||
               Profiles.Any(p => string.Equals(p.Model.FolderName, folder, StringComparison.OrdinalIgnoreCase)))
        {
            folder = $"{baseName}-{counter++}";
        }
        return folder;
    }

    public void Update(ProfileVM vm, CursorProfile updated)
    {
        var before = vm.Model;
        var colorChanged = before.ColorHex != updated.ColorHex;
        var cosmeticsChanged = before.DisplayName != updated.DisplayName
            || before.Emoji != updated.Emoji
            || colorChanged
            || before.DefaultMemoryMB != updated.DefaultMemoryMB
            || before.DefaultProjectPath != updated.DefaultProjectPath;
        vm.Update(updated);
        SaveMetadata();
        Changed?.Invoke();
        // Keep an existing shortcut in sync with name/icon/launch changes.
        if (cosmeticsChanged && !updated.IsSystem && HasShortcut(vm))
            CreateOrUpdateShortcut(vm, announce: false);
        if (colorChanged)
            TitleBarColorizer.Apply(updated, DirectoryFor(updated));
    }

    // MARK: Taskbar shortcuts

    public bool HasShortcut(ProfileVM vm) => ShortcutBuilder.Exists(vm.Model);

    /// <summary>Build (or rebuild) a Start Menu shortcut with a generated icon
    /// for this profile, so it can be pinned to the taskbar.</summary>
    public void CreateOrUpdateShortcut(ProfileVM vm, bool announce = true)
    {
        try
        {
            ShortcutBuilder.CreateOrUpdate(vm.Model, DirectoryFor(vm.Model), Settings.CustomCursorPath);
            if (announce)
            {
                Info?.Invoke(
                    $"A shortcut for \"{vm.Model.DisplayName}\" was added to the Start Menu " +
                    "(Prism folder). Find it in Start, then right-click it and choose " +
                    "\"Pin to taskbar\".");
            }
        }
        catch (Exception e)
        {
            Error?.Invoke($"Could not create the shortcut: {e.Message}");
        }
    }

    public void RemoveShortcut(ProfileVM vm) => ShortcutBuilder.Remove(vm.Model);

    /// <summary>Duplicate a profile; for the built-in one this clones the original
    /// Cursor data into a new managed profile (the original is only read).</summary>
    public async void Duplicate(ProfileVM vm)
    {
        var profile = vm.Model;
        var baseName = profile.IsSystem ? "Main-Cursor-Clone" : profile.FolderName + "-copy";
        var folder = UniqueFolderName(baseName);
        var source = DirectoryFor(profile);
        var dest = Path.Combine(ProfilesDir, folder);

        var copy = profile.Copy();
        copy.FolderName = folder;
        copy.DisplayName = profile.IsSystem ? "Main Cursor Clone" : profile.DisplayName + " Copy";
        copy.CreatedAt = DateTime.UtcNow;
        copy.LastLaunchedAt = null;
        copy.IsPinned = false;
        copy.IsSystem = false;

        vm.IsDuplicating = true;
        try
        {
            await Task.Run(() => CopyDirectory(source, dest));
            Profiles.Add(new ProfileVM(copy));
            SaveMetadata();
            Changed?.Invoke();
            RefreshSizes();
        }
        catch (Exception e)
        {
            Error?.Invoke($"Could not duplicate profile: {e.Message}");
            try { if (Directory.Exists(dest)) Directory.Delete(dest, true); } catch { }
        }
        finally { vm.IsDuplicating = false; }
    }

    private static void CopyDirectory(string source, string dest)
    {
        Directory.CreateDirectory(dest);
        foreach (var dir in Directory.EnumerateDirectories(source, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(dir.Replace(source, dest));
        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            try { File.Copy(file, file.Replace(source, dest), overwrite: true); }
            catch (IOException) { /* locked cache file — skip */ }
        }
    }

    /// <summary>Send the profile folder to the Recycle Bin (recoverable).</summary>
    public void Delete(ProfileVM vm)
    {
        if (vm.Model.IsSystem)
        {
            Error?.Invoke("The built-in Cursor profile can't be deleted from here — it's your original Cursor data.");
            return;
        }
        if (vm.IsRunning)
        {
            Error?.Invoke($"'{vm.Model.DisplayName}' is running. Quit it before deleting.");
            return;
        }
        try
        {
            Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(
                DirectoryFor(vm.Model),
                Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs,
                Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
        }
        catch (Exception e)
        {
            Error?.Invoke($"Could not move profile to Recycle Bin: {e.Message}");
            return;
        }
        RemoveShortcut(vm);
        Profiles.Remove(vm);
        SaveMetadata();
        Changed?.Invoke();
    }

    public void TogglePin(ProfileVM vm)
    {
        var m = vm.Model.Copy();
        m.IsPinned = !m.IsPinned;
        Update(vm, m);
    }

    // MARK: Launch / quit

    public void Launch(ProfileVM vm, string? projectPath = null, int? memoryMB = null, bool newWindow = false)
    {
        var p = vm.Model;
        // Idempotent — also covers profiles adopted from disk that never went through CreateProfile.
        TitleBarColorizer.Apply(p, DirectoryFor(p));
        try
        {
            CursorLauncher.Launch(
                userDataDir: p.IsSystem ? null : DirectoryFor(p),
                cursorPath: string.IsNullOrWhiteSpace(Settings.CustomCursorPath) ? null : Settings.CustomCursorPath,
                memoryMB: memoryMB ?? p.DefaultMemoryMB,
                projectPath: projectPath ?? p.DefaultProjectPath,
                newWindow: newWindow);
        }
        catch (Exception e)
        {
            Error?.Invoke(e.Message);
            return;
        }
        var m = p.Copy();
        m.LastLaunchedAt = DateTime.UtcNow;
        Update(vm, m);
        Task.Delay(2000).ContinueWith(_ => RefreshRunning(),
            TaskScheduler.FromCurrentSynchronizationContext());
    }

    public void Quit(ProfileVM vm)
    {
        CursorLauncher.Quit(vm.RunningPids);
        Task.Delay(1500).ContinueWith(_ => RefreshRunning(),
            TaskScheduler.FromCurrentSynchronizationContext());
    }

    // MARK: Background refresh

    public async void RefreshRunning()
    {
        var snapshot = Profiles.Select(vm => (vm, dir: DirectoryFor(vm.Model), vm.Model.IsSystem)).ToList();
        var processes = await Task.Run(CursorLauncher.ProcessList);
        foreach (var (vm, dir, isSystem) in snapshot)
        {
            vm.RunningPids = isSystem
                ? CursorLauncher.SystemProfilePids(processes)
                : CursorLauncher.Pids(processes, dir);
        }
    }

    public async void RefreshSizes()
    {
        var snapshot = Profiles.Select(vm => (vm, dir: DirectoryFor(vm.Model))).ToList();
        foreach (var (vm, dir) in snapshot)
        {
            var size = await Task.Run(() => DirectorySize(dir));
            vm.SizeBytes = size;
        }
    }

    private static long DirectorySize(string path)
    {
        long total = 0;
        try
        {
            foreach (var file in Directory.EnumerateFiles(path, "*", new EnumerationOptions
                     { RecurseSubdirectories = true, IgnoreInaccessible = true }))
            {
                try { total += new FileInfo(file).Length; } catch { }
            }
        }
        catch { }
        return total;
    }
}
