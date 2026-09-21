using System.Diagnostics;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;

namespace CursorProfiles;

public record ProcessEntry(int Pid, long WorkingSetBytes, string CommandLine);

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

    /// <summary>One WMI snapshot of all Cursor.exe processes: command line plus
    /// live working-set bytes, so detection and memory agree with each other.</summary>
    public static List<ProcessEntry> ProcessList()
    {
        var result = new List<ProcessEntry>();
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "SELECT ProcessId, CommandLine, WorkingSetSize FROM Win32_Process WHERE Name = 'Cursor.exe'");
            foreach (var obj in searcher.Get())
            {
                var pid = Convert.ToInt32(obj["ProcessId"]);
                var cmd = obj["CommandLine"]?.ToString() ?? "";
                long ws = 0;
                try { ws = Convert.ToInt64(obj["WorkingSetSize"]); } catch { /* treat as 0 */ }
                result.Add(new ProcessEntry(pid, ws, cmd));
            }
        }
        catch { /* WMI unavailable — treat as nothing running */ }
        return result;
    }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    /// <summary>Real on-screen window counts per PID. Counted via EnumWindows,
    /// never guessed — invisible windows don't count.</summary>
    public static Dictionary<int, int> VisibleWindowCounts(IEnumerable<int> pids)
    {
        var wanted = new HashSet<int>(pids);
        var counts = new Dictionary<int, int>();
        if (wanted.Count == 0) return counts;
        try
        {
            EnumWindowsProc callback = (hWnd, _) =>
            {
                if (IsWindowVisible(hWnd))
                {
                    GetWindowThreadProcessId(hWnd, out var pid);
                    var id = (int)pid;
                    if (wanted.Contains(id))
                        counts[id] = counts.TryGetValue(id, out var c) ? c + 1 : 1;
                }
                return true;
            };
            EnumWindows(callback, IntPtr.Zero);
            GC.KeepAlive(callback);
        }
        catch { /* enumeration failed — report what we have */ }
        return counts;
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
