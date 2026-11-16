using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace CursorProfiles;

// Prism endpoint on Windows: a local OpenAI/Anthropic-compatible API that
// sends each request with the API keys of an identity (Work, Personal…).
// The work is done by the prism-endpoint helper (Go); this class finds or
// installs it, starts/stops it, edits %APPDATA%\Prism\endpoint.json and
// talks to the helper's admin API. Keys go to Windows Credential Manager
// through the helper — never into the settings file.

public sealed class EndpointCredential
{
    [JsonPropertyName("id")] public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    [JsonPropertyName("provider")] public string Provider { get; set; } = "anthropic";
    [JsonPropertyName("baseURL")] public string BaseUrl { get; set; } = "";

    public static readonly string[] Providers = { "anthropic", "openai", "xai", "compatible" };

    public static string Label(string provider) => provider switch
    {
        "anthropic" => "Anthropic",
        "openai" => "OpenAI",
        "xai" => "xAI",
        _ => "OpenAI-compatible",
    };

    [JsonIgnore] public string ProviderLabel => Label(Provider);
    [JsonIgnore] public bool KeyRequired => Provider != "compatible";
}

public sealed class EndpointIdentity
{
    [JsonPropertyName("id")] public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("colorHex")] public string ColorHex { get; set; } = "#3B82F6";
    [JsonPropertyName("credentials")] public List<EndpointCredential> Credentials { get; set; } = new();
    [JsonPropertyName("defaultModel")] public string DefaultModel { get; set; } = "";
    [JsonPropertyName("token")] public string Token { get; set; } = EndpointConfig.NewToken();
    [JsonPropertyName("fallbackIdentityID"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? FallbackIdentityId { get; set; }
    [JsonPropertyName("monthlyBudget"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? MonthlyBudget { get; set; }
    [JsonPropertyName("budgetAction")] public string BudgetAction { get; set; } = "fallback";
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }

    [JsonIgnore] public string Slug => EndpointConfig.Slugify(Name);
}

public sealed class EndpointRule
{
    [JsonPropertyName("id")] public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    [JsonPropertyName("enabled")] public bool Enabled { get; set; } = true;
    [JsonPropertyName("kind")] public string Kind { get; set; } = "keyword";
    [JsonPropertyName("pattern")] public string Pattern { get; set; } = "";
    [JsonPropertyName("days")] public List<int> Days { get; set; } = new() { 2, 3, 4, 5, 6 };
    [JsonPropertyName("startMinute")] public int StartMinute { get; set; } = 540;
    [JsonPropertyName("endMinute")] public int EndMinute { get; set; } = 1020;
    [JsonPropertyName("identityID")] public string IdentityId { get; set; } = "";
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }

    public static string KindLabel(string kind) => kind switch
    {
        "keyword" => "Message mentions",
        "regex" => "Message matches regex",
        "client" => "Request comes from app",
        _ => "Time of day",
    };
}

public sealed class EndpointConfig
{
    [JsonPropertyName("enabled")] public bool Enabled { get; set; }
    [JsonPropertyName("port")] public int Port { get; set; } = 4848;
    [JsonPropertyName("allowLAN")] public bool AllowLan { get; set; }
    [JsonPropertyName("requireToken")] public bool RequireToken { get; set; } = true;
    [JsonPropertyName("token")] public string Token { get; set; } = NewToken();
    [JsonPropertyName("identities")] public List<EndpointIdentity> Identities { get; set; } = new();
    [JsonPropertyName("activeIdentityID"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ActiveIdentityId { get; set; }
    [JsonPropertyName("tagsEnabled")] public bool TagsEnabled { get; set; } = true;
    [JsonPropertyName("rules")] public List<EndpointRule> Rules { get; set; } = new();
    [JsonPropertyName("modelList")] public string ModelList { get; set; } = "both";
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }

    public EndpointIdentity? Identity(string? id) => Identities.FirstOrDefault(i => i.Id == id);
    public EndpointIdentity? Active => Identity(ActiveIdentityId) ?? Identities.FirstOrDefault();

    public static string NewToken()
    {
        const string alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        var bytes = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
        return "prism-" + new string(bytes.Select(b => alphabet[b % alphabet.Length]).ToArray());
    }

    public static string Slugify(string s)
    {
        var sb = new StringBuilder();
        bool dash = false;
        foreach (var c in s.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(c)) { sb.Append(c); dash = false; }
            else if (!dash && sb.Length > 0) { sb.Append('-'); dash = true; }
        }
        return sb.ToString().TrimEnd('-');
    }
}

// What the helper reports (GET /prism/status).
public sealed class EndpointStatus
{
    [JsonPropertyName("version")] public string Version { get; set; } = "";
    [JsonPropertyName("port")] public int Port { get; set; }
    [JsonPropertyName("keysInFile")] public bool KeysInFile { get; set; }
    [JsonPropertyName("identities")] public List<EndpointIdentityStatus> Identities { get; set; } = new();
    [JsonPropertyName("log")] public List<EndpointLogEntry> Log { get; set; } = new();
    [JsonPropertyName("unpricedModels")] public List<string>? UnpricedModels { get; set; }
}

public sealed class EndpointIdentityStatus
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("slug")] public string Slug { get; set; } = "";
    [JsonPropertyName("active")] public bool Active { get; set; }
    [JsonPropertyName("keys")] public Dictionary<string, bool> Keys { get; set; } = new();
    [JsonPropertyName("monthCost")] public double MonthCost { get; set; }
    [JsonPropertyName("monthRequests")] public int MonthRequests { get; set; }
    [JsonPropertyName("todayCost")] public double TodayCost { get; set; }
    [JsonPropertyName("budget")] public double Budget { get; set; }
    [JsonPropertyName("cooldownUntil")] public DateTime? CooldownUntil { get; set; }
    [JsonPropertyName("models")] public List<string>? Models { get; set; }
}

public sealed class EndpointLogEntry
{
    [JsonPropertyName("date")] public DateTime Date { get; set; }
    [JsonPropertyName("client")] public string Client { get; set; } = "";
    [JsonPropertyName("api")] public string Api { get; set; } = "";
    [JsonPropertyName("identity")] public string Identity { get; set; } = "";
    [JsonPropertyName("identityColor")] public string IdentityColor { get; set; } = "#8E8E98";
    [JsonPropertyName("provider")] public string Provider { get; set; } = "";
    [JsonPropertyName("model")] public string Model { get; set; } = "";
    [JsonPropertyName("reason")] public string Reason { get; set; } = "";
    [JsonPropertyName("status")] public int Status { get; set; }
    [JsonPropertyName("ms")] public int Milliseconds { get; set; }
    [JsonPropertyName("inputTokens")] public int InputTokens { get; set; }
    [JsonPropertyName("outputTokens")] public int OutputTokens { get; set; }
    [JsonPropertyName("cost")] public double? Cost { get; set; }
    [JsonPropertyName("note")] public string? Note { get; set; }
    [JsonPropertyName("error")] public string? Error { get; set; }
}

public sealed class EndpointService
{
    public const string HelperName = "prism-endpoint.exe";
    public static string HelperAsset =>
        System.Runtime.InteropServices.RuntimeInformation.OSArchitecture == System.Runtime.InteropServices.Architecture.Arm64
            ? "prism-endpoint-windows-arm64.exe"
            : "prism-endpoint-windows-amd64.exe";
    const string Repo = "moderniselife/prism";

    static readonly JsonSerializerOptions Json = new() { WriteIndented = true };
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };

    public static string Dir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Prism");
    public static string ConfigPath => Path.Combine(Dir, "endpoint.json");
    static string InstalledHelper => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Prism", HelperName);

    public EndpointConfig Config { get; private set; } = new();

    public EndpointService() => Reload();

    public void Reload()
    {
        try
        {
            if (File.Exists(ConfigPath))
                Config = JsonSerializer.Deserialize<EndpointConfig>(File.ReadAllText(ConfigPath)) ?? new();
        }
        catch { Config = new(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(Dir);
        var tmp = ConfigPath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(Config, Json));
        File.Move(tmp, ConfigPath, overwrite: true);
        _ = Post("/prism/reload", new { });
    }

    // MARK: Helper

    /// prism-endpoint.exe next to Prism.exe, in %LOCALAPPDATA%\Prism, or on PATH.
    public static string? FindHelper()
    {
        var candidates = new List<string>
        {
            Path.Combine(AppContext.BaseDirectory, HelperName),
            InstalledHelper,
        };
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            if (!string.IsNullOrWhiteSpace(dir)) candidates.Add(Path.Combine(dir.Trim(), HelperName));
        return candidates.FirstOrDefault(File.Exists);
    }

    /// Download the helper from the latest GitHub release.
    public static async Task<string> InstallHelperAsync()
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, $"https://api.github.com/repos/{Repo}/releases/latest");
        req.Headers.UserAgent.ParseAdd("Prism-Windows");
        using var resp = await Http.SendAsync(req);
        resp.EnsureSuccessStatusCode();
        var root = JsonNode.Parse(await resp.Content.ReadAsStringAsync());
        var url = root?["assets"]?.AsArray()
            .FirstOrDefault(a => (string?)a?["name"] == HelperAsset)?["browser_download_url"]?.GetValue<string>()
            ?? throw new InvalidOperationException("The latest Prism release has no endpoint helper for Windows yet.");
        Directory.CreateDirectory(Path.GetDirectoryName(InstalledHelper)!);
        var tmp = InstalledHelper + ".download";
        using (var dl = new HttpClient { Timeout = TimeSpan.FromMinutes(5) })
        {
            dl.DefaultRequestHeaders.UserAgent.ParseAdd("Prism-Windows");
            await File.WriteAllBytesAsync(tmp, await dl.GetByteArrayAsync(url));
        }
        File.Move(tmp, InstalledHelper, overwrite: true);
        return InstalledHelper;
    }

    public async Task<EndpointStatus?> StatusAsync()
    {
        try
        {
            var text = await Send(HttpMethod.Get, "/prism/status", null);
            return text == null ? null : JsonSerializer.Deserialize<EndpointStatus>(text);
        }
        catch { return null; }
    }

    /// Start the helper (it keeps running after Prism closes, like a service).
    public async Task<string?> StartAsync()
    {
        var helper = FindHelper();
        if (helper == null) return "The endpoint helper isn't installed.";
        if (!Config.Enabled) { Config.Enabled = true; Save(); }
        try
        {
            Process.Start(new ProcessStartInfo(helper, "serve")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            });
        }
        catch (Exception ex) { return ex.Message; }
        for (int i = 0; i < 20; i++)
        {
            await Task.Delay(250);
            if (await StatusAsync() != null) return null;
        }
        return $"The endpoint didn't start. Is port {Config.Port} in use?";
    }

    public async Task StopAsync()
    {
        Config.Enabled = false;
        Save();
        await Post("/prism/stop", new { });
    }

    public Task<string?> SetActiveAsync(string identityId)
    {
        Config.ActiveIdentityId = identityId;
        Save();
        return Post("/prism/active", new { identityID = identityId });
    }

    /// Store a key in Windows Credential Manager (via the running helper).
    public async Task<string?> SetKeyAsync(string credentialId, string key)
    {
        var text = await Send(HttpMethod.Post, "/prism/key", new { credentialID = credentialId, key });
        if (text != null)
        {
            var node = JsonNode.Parse(text);
            return node?["ok"]?.GetValue<bool>() == true ? null : ErrorText(node) ?? "Couldn't save the key.";
        }
        // Not running: hand the key to the helper on stdin.
        var helper = FindHelper();
        if (helper == null) return "Install the endpoint helper first.";
        try
        {
            using var p = Process.Start(new ProcessStartInfo(helper, $"key {credentialId}")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardError = true,
                RedirectStandardOutput = true,
            })!;
            await p.StandardInput.WriteAsync(key);
            p.StandardInput.Close();
            var err = await p.StandardError.ReadToEndAsync();
            await p.WaitForExitAsync();
            return p.ExitCode == 0 ? null : err.Trim();
        }
        catch (Exception ex) { return ex.Message; }
    }

    /// List the models a saved key can use; null error means it works.
    public async Task<(string? error, List<string> models)> CheckAsync(string credentialId)
    {
        var text = await Send(HttpMethod.Post, "/prism/check", new { credentialID = credentialId });
        if (text == null) return ("The endpoint isn't running.", new());
        var node = JsonNode.Parse(text);
        if (node?["ok"]?.GetValue<bool>() == true)
            return (null, node["models"]?.AsArray().Select(m => m!.GetValue<string>()).ToList() ?? new());
        return (ErrorText(node) ?? "Check failed.", new());
    }

    // {"error": "…"} from the admin API or {"error": {"message": "…"}} from the API proper.
    static string? ErrorText(JsonNode? node) => node?["error"] switch
    {
        JsonValue v => v.ToString(),
        JsonObject o => (string?)o["message"],
        _ => null,
    };

    async Task<string?> Post(string path, object body)
    {
        try { await Send(HttpMethod.Post, path, body); return null; }
        catch (Exception ex) { return ex.Message; }
    }

    async Task<string?> Send(HttpMethod method, string path, object? body)
    {
        using var req = new HttpRequestMessage(method, $"http://127.0.0.1:{Config.Port}{path}");
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Config.Token);
        if (body != null) req.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        try
        {
            using var resp = await Http.SendAsync(req);
            return await resp.Content.ReadAsStringAsync();
        }
        catch (HttpRequestException) { return null; }
        catch (TaskCanceledException) { return null; }
    }

    /// Environment for a Claude Code profile that goes through the endpoint
    /// (null id = the profile's own sign-in, "*" = whichever identity is active).
    public Dictionary<string, string>? ClaudeCodeEnvironment(string? identityId)
    {
        if (identityId == null) return null;
        var token = identityId == "*" ? Config.Token : Config.Identity(identityId)?.Token;
        if (token == null) return null;
        return new()
        {
            ["ANTHROPIC_BASE_URL"] = BaseUrl,
            ["ANTHROPIC_AUTH_TOKEN"] = token,
        };
    }

    // MARK: Setup snippets

    public string BaseUrl => $"http://127.0.0.1:{Config.Port}";

    public string ChatApps(string token) =>
        $"Base URL   {BaseUrl}/v1\nAPI key    {token}\nModel      prism  (follows the active identity)\n           or work/…, personal/… to pin one\n\nOpen WebUI in Docker: http://host.docker.internal:{Config.Port}/v1";

    public string ClaudeCode(string token) =>
        $"$env:ANTHROPIC_BASE_URL = \"{BaseUrl}\"\n$env:ANTHROPIC_AUTH_TOKEN = \"{token}\"";

    public string Codex(string token) =>
        $"# %USERPROFILE%\\.codex\\config.toml\nmodel = \"{(string.IsNullOrEmpty(Config.Active?.DefaultModel) ? "gpt-5-codex" : Config.Active!.DefaultModel)}\"\nmodel_provider = \"prism\"\n\n[model_providers.prism]\nname = \"Prism\"\nbase_url = \"{BaseUrl}/v1\"\nenv_key = \"PRISM_API_KEY\"\nwire_api = \"responses\"\n\n# and once, in PowerShell:\nsetx PRISM_API_KEY {token}";

    public string ClaudeDesktop(string token) =>
        $"Developer → Configure Third-Party Inference…\nInference provider   Gateway\nGateway base URL     {BaseUrl}\nGateway API key      {token}\nGateway auth scheme  Bearer";
}
