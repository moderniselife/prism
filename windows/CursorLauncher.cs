using System.Diagnostics;
using System.IO;
using System.Management;

namespace CursorProfiles;

public record ProcessEntry(int Pid, string CommandLine);

public static class CursorLauncher
{
    public static string[] CandidatePaths()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var programs = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        return new[]
        {
            Path.Combine(local, "Programs", "cursor", "Cursor.exe"),
            Path.Combine(local, "Programs", "Cursor", "Cursor.exe"),
            Path.Combine(programs, "Cursor", "Cursor.exe"),
        };
    }

    /// <summary>Locate Cursor.exe: custom path -> well-known installs -> PATH.</summary>
    public static string? FindCursor(string? customPath)
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
                var p = Path.Combine(dir.Trim(), "Cursor.exe");
                if (File.Exists(p)) return p;
            }
            catch { /* malformed PATH entry */ }
        }
        return null;
    }

    /// <summary>Launch Cursor. Pass userDataDir = null for the built-in default profile.</summary>
    public static void Launch(string? userDataDir, string? cursorPath, int memoryMB,
                              string? projectPath, bool newWindow)
    {
        var exe = FindCursor(cursorPath)
            ?? throw new InvalidOperationException(
                "Cursor could not be found. Install it from cursor.sh or set a custom path in Settings.");

        var psi = new ProcessStartInfo(exe) { UseShellExecute = false };
        if (userDataDir is not null)
        {
            Directory.CreateDirectory(userDataDir);
            psi.ArgumentList.Add("--user-data-dir");
            psi.ArgumentList.Add(userDataDir);
        }
        psi.ArgumentList.Add($"--max-memory={memoryMB}");
        if (newWindow) psi.ArgumentList.Add("--new-window");
        if (!string.IsNullOrWhiteSpace(projectPath)) psi.ArgumentList.Add(projectPath);

        Process.Start(psi);
    }

    /// <summary>One WMI snapshot of all Cursor.exe processes with their command lines.</summary>
    public static List<ProcessEntry> ProcessList()
    {
        var result = new List<ProcessEntry>();
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'Cursor.exe'");
            foreach (var obj in searcher.Get())
            {
                var pid = Convert.ToInt32(obj["ProcessId"]);
                var cmd = obj["CommandLine"]?.ToString() ?? "";
                result.Add(new ProcessEntry(pid, cmd));
            }
        }
        catch { /* WMI unavailable — treat as nothing running */ }
        return result;
    }

    /// <summary>Main Cursor process for a managed profile (matched by --user-data-dir).</summary>
    public static List<int> Pids(List<ProcessEntry> list, string profileDir) =>
        list.Where(p => p.CommandLine.Contains($"--user-data-dir {profileDir}", StringComparison.OrdinalIgnoreCase)
                     || p.CommandLine.Contains($"--user-data-dir \"{profileDir}\"", StringComparison.OrdinalIgnoreCase))
            .Where(p => !p.CommandLine.Contains("--type="))
            .Select(p => p.Pid).ToList();

    /// <summary>Main Cursor process running the built-in profile (no --user-data-dir at all).</summary>
    public static List<int> SystemProfilePids(List<ProcessEntry> list) =>
        list.Where(p => !p.CommandLine.Contains("--type=")
                     && !p.CommandLine.Contains("--user-data-dir"))
            .Select(p => p.Pid).ToList();

    /// <summary>Graceful quit: ask each main window to close.</summary>
    public static void Quit(IEnumerable<int> pids)
    {
        foreach (var pid in pids)
        {
            try { Process.GetProcessById(pid).CloseMainWindow(); }
            catch { /* already gone */ }
        }
    }
}
