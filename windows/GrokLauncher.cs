using System.Diagnostics;
using System.IO;
using System.Management;

namespace CursorProfiles;

/// <summary>
/// Finding, launching and detecting Grok Bot. It's an Electron app whose
/// main process honours SAND_USER_DATA_DIR in release builds: that becomes
/// its userData and moves the agent data root from ~/.grokbot to
/// &lt;dir&gt;\sand-data. The single-instance lock follows, so every profile
/// is its own instance with its own login. Prism also passes a matching
/// --user-data-dir=&lt;dir&gt; purely so the profile shows up in the process
/// list (environment variables are invisible there).
///
/// Keep in sync with tui/grokbot.go and Sources/CursorProfiles/GrokLauncher.swift.
/// </summary>
public static class GrokLauncher
{
    public const string UserDataEnv = "SAND_USER_DATA_DIR";
    /// <summary>Where an isolated profile keeps agents and settings.</summary>
    public const string DataSubdir = "sand-data";

    public static string[] CandidatePaths()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var programs = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        return new[]
        {
            Path.Combine(local, "Programs", "Grok Bot", "Grok Bot.exe"),
            Path.Combine(local, "Programs", "grok-bot", "Grok Bot.exe"),
            Path.Combine(programs, "Grok Bot", "Grok Bot.exe"),
        };
    }

    /// <summary>Locate Grok Bot: custom path -> well-known installs -> PATH.</summary>
    public static string? FindGrokBot(string? customPath)
    {
        if (!string.IsNullOrWhiteSpace(customPath) && File.Exists(customPath))
            return customPath;
        foreach (var p in CandidatePaths())
            if (File.Exists(p)) return p;
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
        {
            if (string.IsNullOrWhiteSpace(dir)) continue;
            try
            {
                foreach (var name in new[] { "Grok Bot.exe", "grok-bot.exe" })
                {
                    var p = Path.Combine(dir.Trim(), name);
                    if (File.Exists(p)) return p;
                }
            }
            catch { /* malformed PATH entry */ }
        }
        return null;
    }

    /// <summary>Electron's default userData for the app (%APPDATA%\Grok Bot).</summary>
    public static string SystemUserDataDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Grok Bot");

    /// <summary>Where the default install keeps agents and settings: ~/.grokbot,
    /// or the pre-rename ~/.cursor/sand on installs that never migrated.</summary>
    public static string SystemDataRoot
    {
        get
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var canonical = Path.Combine(home, ".grokbot");
            if (Directory.Exists(canonical)) return canonical;
            var legacy = Path.Combine(home, ".cursor", "sand");
            return Directory.Exists(legacy) ? legacy : canonical;
        }
    }

    /// <summary>A profile's agent data root.</summary>
    public static string DataRoot(string profileDir, bool isSystem) =>
        isSystem ? SystemDataRoot : Path.Combine(profileDir, DataSubdir);

    /// <summary>Launch Grok Bot. profileDir = null for the built-in profile:
    /// no flag and no environment, exactly like opening it from Start.</summary>
    public static void Launch(string? profileDir, string? grokPath)
    {
        var exe = FindGrokBot(grokPath)
            ?? throw new InvalidOperationException(
                "Grok Bot could not be found. Install it or set a custom path in Settings.");
        var psi = new ProcessStartInfo(exe) { UseShellExecute = false };
        // Never pass a stray isolation switch from our own environment on.
        psi.Environment.Remove(UserDataEnv);
        psi.Environment.Remove("SAND_DATA_ROOT");
        if (profileDir is not null)
        {
            Directory.CreateDirectory(profileDir);
            psi.ArgumentList.Add($"--user-data-dir={profileDir}");
            psi.Environment[UserDataEnv] = profileDir;
        }
        Process.Start(psi);
    }

    /// <summary>One WMI snapshot of Grok Bot processes.</summary>
    public static List<ProcessEntry> ProcessList()
    {
        var result = new List<ProcessEntry>();
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "SELECT ProcessId, CommandLine, WorkingSetSize, ExecutablePath FROM Win32_Process " +
                "WHERE Name = 'Grok Bot.exe' OR Name = 'grok-bot.exe'");
            foreach (var obj in searcher.Get())
            {
                var pid = Convert.ToInt32(obj["ProcessId"]);
                var cmd = obj["CommandLine"]?.ToString() ?? "";
                var exe = obj["ExecutablePath"]?.ToString() ?? "";
                long ws = 0;
                try { ws = Convert.ToInt64(obj["WorkingSetSize"]); } catch { /* treat as 0 */ }
                result.Add(new ProcessEntry(pid, ws, cmd, exe));
            }
        }
        catch { /* WMI unavailable: treat as nothing running */ }
        return result;
    }

    /// <summary>
    /// True for the app's main (window) process. Grok Bot also runs its
    /// local-exec daemon and agent coordinator through the same executable
    /// (an entry .cjs script), and Chromium helpers carry --type=.
    /// </summary>
    public static bool IsMain(string commandLine)
    {
        if (string.IsNullOrWhiteSpace(commandLine)) return false;
        if (commandLine.Contains("--type=", StringComparison.Ordinal)) return false;
        if (commandLine.Contains(".cjs", StringComparison.OrdinalIgnoreCase)) return false;
        if (commandLine.Contains("app.asar", StringComparison.OrdinalIgnoreCase)) return false;
        return true;
    }

    private static readonly System.Text.RegularExpressions.Regex UserDataDirArg = new(
        "\"--user-data-dir=([^\"]*)\"|--user-data-dir=\"([^\"]*)\"|--user-data-dir=([^\\s\"]+)",
        System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    /// <summary>Every --user-data-dir value on a command line, whether the
    /// whole argument, just the value, or nothing is quoted.</summary>
    public static IEnumerable<string> UserDataDirs(string commandLine) =>
        UserDataDirArg.Matches(commandLine).Select(m =>
            m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Success ? m.Groups[2].Value : m.Groups[3].Value);

    private static string NormalizeDir(string path) =>
        path.Trim().TrimEnd('\\', '/');

    /// <summary>Main process of a managed profile: its --user-data-dir must be
    /// exactly this folder (C:\p\Work must not match C:\p\Work2).</summary>
    public static List<int> Pids(List<ProcessEntry> list, string profileDir) =>
        list.Where(p => IsMain(p.CommandLine) && UserDataDirs(p.CommandLine)
                .Any(d => string.Equals(NormalizeDir(d), NormalizeDir(profileDir), StringComparison.OrdinalIgnoreCase)))
            .Select(p => p.Pid).ToList();

    /// <summary>Main process of the built-in profile (no --user-data-dir).</summary>
    public static List<int> SystemPids(List<ProcessEntry> list) =>
        list.Where(p => IsMain(p.CommandLine) && !p.CommandLine.Contains("--user-data-dir"))
            .Select(p => p.Pid).ToList();
}
