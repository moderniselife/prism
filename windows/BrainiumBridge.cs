using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CursorProfiles;

/// <summary>
/// Second brain (Brainium, github.com/moderniselife/brainium). Prism stays
/// thin: it finds node.exe and a Brainium checkout and runs its CLI.
/// Brainium's own config is the source of truth for the personal brain,
/// capture and the summarizer.
///
/// Keep in sync with Sources/CursorProfiles/BrainiumBridge.swift,
/// tui/brainium.go and linux/prism.py.
/// </summary>
public sealed class BrainiumBridge
{
    public string Node { get; }
    public string Cli { get; }

    private BrainiumBridge(string node, string cli)
    {
        Node = node;
        Cli = cli;
    }

    public sealed class Status
    {
        [JsonPropertyName("version")] public string? Version { get; set; }
        [JsonPropertyName("personalBrain")] public string? PersonalBrain { get; set; }
        [JsonPropertyName("personalExists")] public bool PersonalExists { get; set; }
        [JsonPropertyName("personalRemote")] public string? PersonalRemote { get; set; }
        [JsonPropertyName("capture")] public bool Capture { get; set; }
        [JsonPropertyName("pending")] public int Pending { get; set; }
        [JsonPropertyName("summarizer")] public SummarizerInfo? Summarizer { get; set; }
    }

    public sealed class SummarizerInfo
    {
        [JsonPropertyName("provider")] public string? Provider { get; set; }
        [JsonPropertyName("url")] public string? Url { get; set; }
        [JsonPropertyName("model")] public string? Model { get; set; }
        [JsonPropertyName("apiKeyEnv")] public string? ApiKeyEnv { get; set; }
        [JsonPropertyName("hasKey")] public bool HasKey { get; set; }
    }

    /// <summary>Summarizers Brainium supports, with the labels Prism shows.</summary>
    public static readonly (string Id, string Label)[] Providers =
    {
        ("agent", "Your AI, via MCP (no extra cost)"),
        ("none", "No AI (mechanical summary)"),
        ("anthropic", "Anthropic API"),
        ("openai", "OpenAI API"),
        ("bonsai", "Bonsai (self-hosted)"),
        ("openai-compatible", "Other OpenAI-compatible API"),
    };

    public const string NotFoundMessage =
        "Brainium isn't set up yet. Open Settings → Second brain and click Install.";

    public static BrainiumBridge? Resolve(string cliPath, string nodePath) =>
        FindNode(nodePath) is { } node && FindCli(cliPath) is { } cli ? new BrainiumBridge(node, cli) : null;

    private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>node.exe: custom -> PATH -> official installer -> nvm-windows -> Volta.</summary>
    public static string? FindNode(string? custom)
    {
        if (!string.IsNullOrWhiteSpace(custom) && File.Exists(custom)) return custom;
        var candidates = new List<string>();
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
            if (!string.IsNullOrWhiteSpace(dir))
            {
                try { candidates.Add(Path.Combine(dir.Trim(), "node.exe")); } catch { /* bad entry */ }
            }
        var programs = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        candidates.Add(Path.Combine(programs, "nodejs", "node.exe"));
        candidates.Add(Path.Combine(local, "Programs", "nodejs", "node.exe"));
        if (Environment.GetEnvironmentVariable("NVM_SYMLINK") is { Length: > 0 } nvmLink)
            candidates.Add(Path.Combine(nvmLink, "node.exe"));
        var nvmHome = Environment.GetEnvironmentVariable("NVM_HOME") is { Length: > 0 } h ? h : Path.Combine(roaming, "nvm");
        if (Directory.Exists(nvmHome))
        {
            foreach (var v in Directory.EnumerateDirectories(nvmHome, "v*")
                         .OrderByDescending(d => VersionKey(Path.GetFileName(d))))
                candidates.Add(Path.Combine(v, "node.exe"));
        }
        candidates.Add(Path.Combine(local, "Volta", "bin", "node.exe"));
        return candidates.FirstOrDefault(File.Exists);
    }

    private static Version VersionKey(string name) =>
        Version.TryParse(name.TrimStart('v'), out var v) ? v : new Version(0, 0);

    /// <summary>bin\brainium.mjs: custom (checkout or script) -> BRAINIUM_HOME -> common clone spots.</summary>
    public static string? FindCli(string? custom)
    {
        if (!string.IsNullOrWhiteSpace(custom) && custom.EndsWith(".mjs", StringComparison.OrdinalIgnoreCase)
            && File.Exists(custom))
            return custom;
        var dirs = new List<string>();
        if (!string.IsNullOrWhiteSpace(custom)) dirs.Add(custom);
        if (Environment.GetEnvironmentVariable("BRAINIUM_HOME") is { Length: > 0 } env) dirs.Add(env);
        dirs.AddRange(new[] { "brainium", @"Projects\brainium", @"src\brainium", @"code\brainium", @"source\repos\brainium" }
            .Select(d => Path.Combine(Home, d)));
        return dirs.Select(d => Path.Combine(d, "bin", "brainium.mjs")).FirstOrDefault(File.Exists);
    }

    /// <summary>Checkout folder for a CLI path (…\bin\brainium.mjs).</summary>
    public static string CheckoutDir(string cli)
    {
        var bin = Path.GetDirectoryName(cli) ?? cli;
        return Path.GetFileName(bin).Equals("bin", StringComparison.OrdinalIgnoreCase)
            ? Path.GetDirectoryName(bin) ?? bin : bin;
    }

    /// <summary>Run the CLI; throws with its stderr on failure.</summary>
    public string Run(params string[] args)
    {
        var psi = new ProcessStartInfo(Node)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        psi.ArgumentList.Add(Cli);
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var process = Process.Start(psi) ?? throw new InvalidOperationException("Could not start node.");
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        process.WaitForExit();
        if (process.ExitCode != 0)
        {
            var message = stderr.Result.Trim();
            throw new InvalidOperationException(message.Length > 0 ? message : $"brainium exited with {process.ExitCode}");
        }
        return stdout.Result;
    }

    public Status GetStatus() =>
        JsonSerializer.Deserialize<Status>(Run("status", "--json")) ?? new Status();

    /// <summary>The CLI call that wires (or unwires) one profile, or null when
    /// the app has nothing local to wire (Grok Bot gets a snippet instead).
    /// Cursor's MCP config is shared by every profile.</summary>
    public static string[]? WireArguments(string app, string profileDir, bool isSystem, bool capture, bool enable = true)
    {
        var verb = enable ? "wire" : "unwire";
        switch (CursorProfile.NormalizeApp(app))
        {
            case CursorProfile.AppClaudeCode:
                var args = new List<string> { verb, "--app", "claude-code", "--profile", profileDir, "--json" };
                if (isSystem) args.Add("--system");
                if (enable && capture) args.Add("--capture");
                return args.ToArray();
            case CursorProfile.AppClaudeDesktop:
                return new[] { verb, "--app", "claude-desktop", "--profile", profileDir, "--json" };
            case CursorProfile.AppCursor:
                return new[] { verb, "--app", "cursor", "--json" };
            default:
                return null;
        }
    }

    /// <summary>Wire or unwire every listed profile (Cursor's shared config once).</summary>
    public string WireAll(IEnumerable<(string App, string Dir, bool IsSystem)> profiles, bool enable)
    {
        var st = GetStatus();
        if (enable && !st.PersonalExists)
            throw new InvalidOperationException("Create your personal brain first.");
        var done = 0;
        var cursorDone = false;
        var problems = new List<string>();
        foreach (var p in profiles)
        {
            if (WireArguments(p.App, p.Dir, p.IsSystem, st.Capture, enable) is not { } args) continue;
            if (CursorProfile.NormalizeApp(p.App) == CursorProfile.AppCursor)
            {
                if (cursorDone) { done++; continue; }
                cursorDone = true;
            }
            try { Run(args); done++; }
            catch (Exception e) { problems.Add($"{Path.GetFileName(p.Dir)}: {e.Message}"); }
        }
        var summary = $"{(enable ? "Wired" : "Unwired")} {done} profile{(done == 1 ? "" : "s")}.";
        return problems.Count == 0 ? summary : summary + " Problems: " + string.Join("; ", problems);
    }
}

/// <summary>
/// One-click setup. Brainium: git clone into %USERPROFILE%\brainium when git
/// is installed (so Update can pull), otherwise the GitHub zip. Node.js:
/// winget when available, otherwise the latest LTS installer from nodejs.org.
/// </summary>
public static class BrainiumSetup
{
    public const string RepoUrl = "https://github.com/moderniselife/brainium.git";
    public const string ZipUrl = "https://codeload.github.com/moderniselife/brainium/zip/refs/heads/main";
    public const string NodeIndexUrl = "https://nodejs.org/dist/index.json";

    public static string DefaultDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "brainium");

    private static readonly HttpClient Http = new();

    public static string? FindOnPath(string exe)
    {
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
        {
            if (string.IsNullOrWhiteSpace(dir)) continue;
            try
            {
                var p = Path.Combine(dir.Trim(), exe);
                if (File.Exists(p)) return p;
            }
            catch { /* malformed PATH entry */ }
        }
        return null;
    }

    public static string? Git =>
        FindOnPath("git.exe")
        ?? new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Git", "cmd", "git.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Git", "cmd", "git.exe"),
        }.FirstOrDefault(File.Exists);

    public static string? Winget =>
        FindOnPath("winget.exe")
        ?? new[] { Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                "Microsoft", "WindowsApps", "winget.exe") }.FirstOrDefault(File.Exists);

    /// <summary>Run a tool to completion; throws with the tail of its output.</summary>
    public static string RunTool(string exe, params string[] args)
    {
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var process = Process.Start(psi) ?? throw new InvalidOperationException($"Could not start {Path.GetFileName(exe)}.");
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        process.WaitForExit();
        var output = (stdout.Result + "\n" + stderr.Result).Trim();
        if (process.ExitCode != 0)
        {
            var tail = string.Join(" ", output.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).TakeLast(3));
            throw new InvalidOperationException(tail.Length > 0 ? tail : $"{Path.GetFileName(exe)} exited with {process.ExitCode}");
        }
        return output;
    }

    public static async Task<string> InstallBrainiumAsync(string? dir = null)
    {
        dir ??= DefaultDir;
        if (File.Exists(Path.Combine(dir, "bin", "brainium.mjs")))
            return $"Brainium is already at {dir}.";
        if (Directory.Exists(dir) && Directory.EnumerateFileSystemEntries(dir).Any())
            throw new InvalidOperationException($"{dir} already exists and isn't Brainium. Move it aside, or use “Use existing…”.");

        if (Git is { } git)
        {
            if (Directory.Exists(dir)) Directory.Delete(dir);
            await Task.Run(() => RunTool(git, "clone", "--depth", "1", RepoUrl, dir));
        }
        else
        {
            var staging = Path.Combine(Path.GetTempPath(), "brainium-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(staging);
            try
            {
                var zip = Path.Combine(staging, "brainium.zip");
                await using (var stream = await Http.GetStreamAsync(ZipUrl))
                await using (var file = File.Create(zip))
                    await stream.CopyToAsync(file);
                var extract = Path.Combine(staging, "x");
                ZipFile.ExtractToDirectory(zip, extract);
                var root = Directory.EnumerateDirectories(extract).FirstOrDefault()
                    ?? throw new InvalidOperationException("The Brainium download was empty.");
                if (Directory.Exists(dir)) Directory.Delete(dir);
                Directory.Move(root, dir);
            }
            finally { try { Directory.Delete(staging, true); } catch { /* temp */ } }
        }
        if (!File.Exists(Path.Combine(dir, "bin", "brainium.mjs")))
            throw new InvalidOperationException($"Downloaded Brainium, but {dir}\\bin\\brainium.mjs is missing.");
        return $"Installed Brainium at {dir}.";
    }

    public static string UpdateBrainium(string dir)
    {
        if (!Directory.Exists(Path.Combine(dir, ".git")) || Git is not { } git)
            throw new InvalidOperationException($"{dir} isn't a git checkout, so it can't be updated in place.");
        var output = RunTool(git, "-C", dir, "pull", "--ff-only");
        return output.Contains("Already up to date") ? "Brainium is up to date." : "Updated Brainium.";
    }

    public static async Task<string> InstallNodeAsync()
    {
        if (Winget is { } winget)
        {
            await Task.Run(() => RunTool(winget, "install", "--id", "OpenJS.NodeJS.LTS", "-e", "--silent",
                "--accept-package-agreements", "--accept-source-agreements"));
            return "Installed Node.js with winget.";
        }

        using var index = JsonDocument.Parse(await Http.GetStringAsync(NodeIndexUrl));
        var lts = index.RootElement.EnumerateArray()
            .FirstOrDefault(r => r.TryGetProperty("lts", out var l) && l.ValueKind == JsonValueKind.String);
        if (lts.ValueKind != JsonValueKind.Object || lts.GetProperty("version").GetString() is not { } version)
            throw new InvalidOperationException("Couldn't find the latest Node.js release.");
        var arch = RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "arm64" : "x64";
        var url = $"https://nodejs.org/dist/{version}/node-{version}-{arch}.msi";
        var downloads = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        Directory.CreateDirectory(downloads);
        var target = Path.Combine(downloads, $"node-{version}-{arch}.msi");
        await using (var stream = await Http.GetStreamAsync(url))
        await using (var file = File.Create(target))
            await stream.CopyToAsync(file);
        Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
        return $"Opened the Node.js {version} installer. Finish it, then click Check again.";
    }
}
