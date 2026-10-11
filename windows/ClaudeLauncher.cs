using System.Diagnostics;
using System.IO;
using System.Management;

namespace CursorProfiles;

/// <summary>
/// Finding &amp; launching Claude Code (CLI, via CLAUDE_CONFIG_DIR) and
/// Claude Desktop (Electron app, via --user-data-dir). Mirrors the documented
/// mechanisms: CLAUDE_CONFIG_DIR is the official multi-account switch, and
/// --user-data-dir is the standard Electron isolation flag.
/// </summary>
public static class ClaudeLauncher
{
    public static string[] DesktopCandidatePaths()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var programs = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        return new[]
        {
            // Classic installer locations FIRST: only real executables honor
            // --user-data-dir. The Store alias is a last resort (it opens the
            // main app fine, but Windows drops its launch flags).
            Path.Combine(local, "Programs", "Claude", "Claude.exe"),
            Path.Combine(local, "AnthropicClaude", "Claude.exe"),
            Path.Combine(programs, "Claude", "Claude.exe"),
            // Microsoft Store app execution alias (0-byte shim).
            Path.Combine(local, "Microsoft", "WindowsApps", "claude-desktop.exe"),
        };
    }

    /// <summary>
    /// True when exe is the Store alias. Verified on-machine: launching it
    /// with --user-data-dir leaves the target dir empty — Windows activates
    /// the existing instance and drops the flags. Isolated Store launches are
    /// therefore refused (see LaunchDesktop); only the main profile may use it.
    /// </summary>
    public static bool IsStoreAlias(string? exePath) =>
        !string.IsNullOrWhiteSpace(exePath)
        && Path.GetFileName(exePath).Equals("claude-desktop.exe", StringComparison.OrdinalIgnoreCase)
        && exePath.Contains("WindowsApps", StringComparison.OrdinalIgnoreCase);

    /// <summary>Locate the Claude Code CLI: custom path -> PATH (claude.exe/.cmd).</summary>
    public static string? FindClaudeCode(string? customPath)
    {
        if (!string.IsNullOrWhiteSpace(customPath) && File.Exists(customPath))
            return customPath;

        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
        {
            if (string.IsNullOrWhiteSpace(dir)) continue;
            try
            {
                foreach (var name in new[] { "claude.exe", "claude.cmd", "claude" })
                {
                    var p = Path.Combine(dir.Trim(), name);
                    if (File.Exists(p)) return p;
                }
            }
            catch { /* malformed PATH entry */ }
        }
        return null;
    }

    /// <summary>Locate Claude Desktop: custom path -> well-known installs -> PATH.</summary>
    public static string? FindClaudeDesktop(string? customPath)
    {
        if (!string.IsNullOrWhiteSpace(customPath) && File.Exists(customPath))
            return customPath;

        foreach (var p in DesktopCandidatePaths())
            if (File.Exists(p)) return p;

        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
        {
            if (string.IsNullOrWhiteSpace(dir)) continue;
            try
            {
                var p = Path.Combine(dir.Trim(), "claude-desktop.exe");
                if (File.Exists(p)) return p;
            }
            catch { /* malformed PATH entry */ }
        }
        return null;
    }

    /// <summary>
    /// Open a terminal running the Claude Code CLI with this profile as its
    /// config dir. The CLI is interactive and needs its own console, so it is
    /// launched in a new window rather than headless. First launch walks
    /// through login for the new account.
    /// </summary>
    public static void LaunchCode(string profileDir, string displayName,
                                  string? codePath, string? projectPath, bool isSystem)
    {
        var exe = FindClaudeCode(codePath)
            ?? throw new InvalidOperationException(
                "Claude Code could not be found. Install it (see code.claude.com/docs) or set a custom path in Settings.");

        if (!isSystem) Directory.CreateDirectory(profileDir);

        var workDir = !string.IsNullOrWhiteSpace(projectPath) && Directory.Exists(projectPath)
            ? projectPath
            : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        // cmd /k keeps the window open so login prompts stay visible.
        var inner = $"set \"CLAUDE_CONFIG_DIR={profileDir}\" && \"{exe}\"";
        var psi = new ProcessStartInfo("cmd.exe",
            $"/c start \"Prism - {displayName}\" /D \"{workDir}\" cmd.exe /k \"{inner}\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        Process.Start(psi);
    }

    /// <summary>
    /// Copy-pasteable command for the profile (shown when the CLI is missing
    /// or for terminal users).
    /// </summary>
    public static string CodeCommand(string profileDir) =>
        $"set \"CLAUDE_CONFIG_DIR={profileDir}\" && claude";

    /// <summary>Launch Claude Desktop. Pass userDataDir = null for the built-in profile.</summary>
    /// <summary>
    /// Newest classic-installer (Squirrel) build under AnthropicClaudepp-*,
    /// or null. Only unpackaged executables honor --user-data-dir; verified
    /// on-machine: it starts a fully separate instance (own login, own data)
    /// alongside the Store build.
    /// </summary>
    public static string? FindClassicDesktop(string? customPath)
    {
        if (!string.IsNullOrWhiteSpace(customPath) && File.Exists(customPath) && !IsStoreAlias(customPath)
            && !customPath.Contains("WindowsApps", StringComparison.OrdinalIgnoreCase))
            return customPath;

        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        try
        {
            var root = Path.Combine(local, "AnthropicClaude");
            if (Directory.Exists(root))
            {
                var newest = Directory.GetDirectories(root, "app-*")
                    .Select(d => (dir: d, ver: ParseVersion(Path.GetFileName(d)[4..])))
                    .Where(t => File.Exists(Path.Combine(t.dir, "claude.exe")))
                    .OrderByDescending(t => t.ver).FirstOrDefault();
                if (newest.dir is not null) return Path.Combine(newest.dir, "claude.exe");
            }
        }
        catch { /* unreadable install dir */ }

        foreach (var p in DesktopCandidatePaths())
            if (!IsStoreAlias(p) && File.Exists(p)) return p;
        return null;
    }

    static Version ParseVersion(string s) => Version.TryParse(s, out var v) ? v : new Version(0, 0);

    public const string DownloadUrl = "https://claude.com/download";

    /// <summary>
    /// Launch Claude Desktop. profileDir = null opens the built-in Main
    /// profile with whichever install exists. A managed profile needs the
    /// classic build and is started with its own --user-data-dir, so any
    /// number of profiles can run side by side.
    /// </summary>
    public static void LaunchDesktop(string? profileDir, string? desktopPath, bool newWindow)
    {
        string exe;
        if (profileDir is null)
        {
            exe = FindClaudeDesktop(desktopPath)
                ?? throw new DesktopInstallRequiredException(
                    "Claude Desktop isn't installed. Install it from claude.com/download.");
        }
        else
        {
            exe = FindClassicDesktop(desktopPath)
                ?? throw new DesktopInstallRequiredException(
                    "Separate Claude Desktop profiles need the standalone installer version of Claude Desktop " +
                    "(the Microsoft Store version can't run extra profiles). Install it from claude.com/download " +
                    "— you can keep the Store version too.");
        }

        var psi = new ProcessStartInfo(exe) { UseShellExecute = false };
        if (profileDir is not null)
        {
            Directory.CreateDirectory(profileDir);
            psi.ArgumentList.Add($"--user-data-dir={profileDir}");
        }
        if (newWindow) psi.ArgumentList.Add("--new-window");
        Process.Start(psi);
    }

    /// <summary>
    /// One WMI snapshot of Claude Desktop processes. The bundled Claude Code
    /// helper shares the claude.exe name, so callers must exclude
    /// claude-code paths (see IsDesktopMain). ExecutablePath is captured
    /// because Store builds hide their command lines entirely.
    /// </summary>
    public static List<ProcessEntry> DesktopProcessList()
    {
        var result = new List<ProcessEntry>();
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "SELECT ProcessId, CommandLine, WorkingSetSize, ExecutablePath FROM Win32_Process " +
                "WHERE Name = 'claude.exe' OR Name = 'claude-desktop.exe'");
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
        catch { /* WMI unavailable — treat as nothing running */ }
        return result;
    }

    /// <summary>
    /// True for the Desktop main executable. Rejects the bundled claude-code
    /// helper (same exe name, lives under a claude-code path) and requires a
    /// token boundary so helpers don't match.
    ///
    /// Residual risk: a standalone `claude` CLI named claude.exe running
    /// without --user-data-dir can light up the built-in Desktop as running.
    /// Managed profiles are unaffected (their --user-data-dir match is exact,
    /// and the CLI never takes that flag).
    /// </summary>
    public static bool IsDesktopMain(string commandLine)
    {
        if (string.IsNullOrWhiteSpace(commandLine)) return false;
        if (commandLine.Contains("claude-code", StringComparison.OrdinalIgnoreCase))
            return false;
        if (commandLine.Contains("--type=", StringComparison.Ordinal)) return false;
        return true;
    }

    /// <summary>Main Desktop process for a managed profile (matched by --user-data-dir).</summary>
    public static List<int> DesktopPids(List<ProcessEntry> list, string profileDir) =>
        list.Where(p => IsDesktopMain(p.CommandLine) &&
                     (p.CommandLine.Contains($"--user-data-dir={profileDir}", StringComparison.OrdinalIgnoreCase)
                   || p.CommandLine.Contains($"--user-data-dir=\"{profileDir}\"", StringComparison.OrdinalIgnoreCase)
                   || p.CommandLine.Contains($"--user-data-dir {profileDir}", StringComparison.OrdinalIgnoreCase)
                   || p.CommandLine.Contains($"--user-data-dir \"{profileDir}\"", StringComparison.OrdinalIgnoreCase)))
            .Select(p => p.Pid).ToList();

    /// <summary>Main Desktop process running the built-in profile.</summary>
    public static List<int> SystemDesktopPids(List<ProcessEntry> list) =>
        list.Where(p => !string.IsNullOrWhiteSpace(p.CommandLine)
                     ? IsDesktopMain(p.CommandLine) && !p.CommandLine.Contains("--user-data-dir")
                     : IsStoreDesktopExe(p.ExePath))
            .Select(p => p.Pid).ToList();

    /// <summary>
    /// Store builds report empty command lines via WMI; match by package exe
    /// path instead. The bundled claude-code helper is excluded by path, and
    /// a standalone CLI never lives under WindowsApps.
    /// </summary>
    public static bool IsStoreDesktopExe(string? exePath) =>
        !string.IsNullOrWhiteSpace(exePath)
        && exePath.Contains("windowsapps", StringComparison.OrdinalIgnoreCase)
        && !exePath.Contains("claude-code", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Electron holds a lockfile inside a running user-data-dir. Combined with
    /// a live Desktop process this identifies the running profile when the
    /// Store build hides command lines from WMI (they come back empty).
    /// </summary>
    public static bool DesktopLockHeld(string profileDir)
    {
        try { return File.Exists(Path.Combine(profileDir, "lockfile")); }
        catch { return false; }
    }

    /// <summary>Graceful quit: ask each main window to close. Skips sentinel PIDs.</summary>
    public static void Quit(IEnumerable<int> pids)
    {
        foreach (var pid in pids)
        {
            if (pid <= 0) continue;
            try { Process.GetProcessById(pid).CloseMainWindow(); }
            catch { /* already gone */ }
        }
    }
}

/// <summary>Thrown when the standalone Claude Desktop installer build is required but missing.</summary>
public class DesktopInstallRequiredException : InvalidOperationException
{
    public DesktopInstallRequiredException(string message) : base(message) { }
}
