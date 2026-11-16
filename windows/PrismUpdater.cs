using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Text.Json.Nodes;

namespace CursorProfiles;

/// Checks GitHub for a newer Prism and installs it: the running Prism.exe is
/// renamed out of the way (Windows allows renaming a running exe), the new
/// one takes its place and starts, and the old copy is removed next launch.
public static class PrismUpdater
{
    const string Repo = "moderniselife/prism";
    const string Asset = "Prism.exe";

    public sealed record Release(string Tag, Version Version, string Page, string? ExeUrl);

    public static Version Current =>
        Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 0, 0);

    public static string CurrentText => $"{Current.Major}.{Current.Minor}.{Current.Build}";

    static string? ExePath => Environment.ProcessPath;
    static string? OldPath => ExePath == null ? null : Path.ChangeExtension(ExePath, ".old.exe");

    /// Remove the copy left behind by the last update.
    public static void CleanUp()
    {
        try { if (OldPath is { } old && File.Exists(old)) File.Delete(old); } catch { /* still running: next time */ }
    }

    public static async Task<Release?> CheckAsync()
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("Prism-Windows/" + CurrentText);
            var root = JsonNode.Parse(await http.GetStringAsync($"https://api.github.com/repos/{Repo}/releases/latest"));
            var tag = (string?)root?["tag_name"];
            if (tag == null || !Version.TryParse(tag.TrimStart('v'), out var v)) return null;
            var normalized = new Version(v.Major, v.Minor, Math.Max(0, v.Build));
            if (normalized <= new Version(Current.Major, Current.Minor, Math.Max(0, Current.Build))) return null;
            var exe = root?["assets"]?.AsArray()
                .FirstOrDefault(a => (string?)a?["name"] == Asset)?["browser_download_url"]?.GetValue<string>();
            return new Release(tag, normalized, (string?)root?["html_url"] ?? $"https://github.com/{Repo}/releases/latest", exe);
        }
        catch { return null; }
    }

    /// Whether this copy can replace itself (a published single-file Prism.exe).
    public static bool CanInstall(Release r) =>
        r.ExeUrl != null && ExePath != null &&
        string.Equals(Path.GetFileName(ExePath), Asset, StringComparison.OrdinalIgnoreCase);

    public static async Task InstallAsync(Release r)
    {
        if (!CanInstall(r)) { OpenPage(r); return; }
        var exe = ExePath!;
        var download = exe + ".download";
        using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) })
        {
            http.DefaultRequestHeaders.UserAgent.ParseAdd("Prism-Windows/" + CurrentText);
            await using var input = await http.GetStreamAsync(r.ExeUrl);
            await using var output = File.Create(download);
            await input.CopyToAsync(output);
        }
        var old = OldPath!;
        if (File.Exists(old)) File.Delete(old);
        File.Move(exe, old);
        try { File.Move(download, exe); }
        catch
        {
            File.Move(old, exe); // put things back
            throw;
        }
        Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true });
        System.Windows.Application.Current.Shutdown();
    }

    public static void OpenPage(Release r)
    {
        try { Process.Start(new ProcessStartInfo(r.Page) { UseShellExecute = true }); } catch { }
    }
}
