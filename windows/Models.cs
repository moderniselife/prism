using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Media;

namespace CursorProfiles;

public class CursorProfile
{
    /// Reserved marker for the user's original Cursor profile (%APPDATA%\Cursor).
    /// Never a real folder in ~/.cursor_profiles, never deletable from the app.
    public const string SystemFolderName = "__cursor-default__";
    /// Reserved marker for the built-in Claude Code profile (the real
    /// %USERPROFILE%\.claude). Never a real folder, never deletable.
    public const string SystemCodeFolderName = "__claude-code-default__";
    /// Reserved marker for the built-in Claude Desktop profile (the real
    /// Electron userData dir). Never a real folder, never deletable.
    public const string SystemDesktopFolderName = "__claude-desktop-default__";
    /// Reserved marker for the built-in Grok Bot profile (its default
    /// userData + ~/.grokbot). Never a real folder, never deletable.
    public const string SystemGrokFolderName = "__grok-bot-default__";

    /// App identifiers. Absent in files predating multi-app support (= cursor).
    public const string AppCursor = "cursor";
    public const string AppClaudeCode = "claude-code";
    public const string AppClaudeDesktop = "claude-desktop";
    public const string AppGrokBot = "grok-bot";

    /// <summary>Every app Prism manages, in display order.</summary>
    public static readonly string[] AllApps = { AppCursor, AppClaudeCode, AppClaudeDesktop, AppGrokBot };

    public static readonly string[] SystemFolderNames =
        { SystemFolderName, SystemCodeFolderName, SystemDesktopFolderName, SystemGrokFolderName };

    /// <summary>Legacy/unknown app values are Cursor profiles.</summary>
    public static string NormalizeApp(string? app) => app switch
    {
        AppClaudeCode => AppClaudeCode,
        AppClaudeDesktop => AppClaudeDesktop,
        AppGrokBot => AppGrokBot,
        _ => AppCursor,
    };

    public static string LabelFor(string app) => NormalizeApp(app) switch
    {
        AppClaudeCode => "Claude Code",
        AppClaudeDesktop => "Claude Desktop",
        AppGrokBot => "Grok Bot",
        _ => "Cursor",
    };

    /// <summary>Grok Bot's agents live on the signed-in account, so its copy
    /// carries settings only and gets plainer words than "overflow".</summary>
    public static string CopyChoiceLabelFor(string app) =>
        NormalizeApp(app) == AppGrokBot ? "Copy settings" : "Overflow account";

    [JsonPropertyName("folderName")] public string FolderName { get; set; } = "";
    [JsonPropertyName("displayName")] public string DisplayName { get; set; } = "";
    [JsonPropertyName("app")] public string App { get; set; } = AppCursor;
    // NOTE: older .profiles.json files may contain an "emoji" key. It has no
    // corresponding property, and System.Text.Json skips unknown keys, so old
    // files still load and new files simply omit it.
    [JsonPropertyName("colorHex")] public string ColorHex { get; set; } = "#6366F1";
    [JsonPropertyName("defaultMemoryMB")] public int DefaultMemoryMB { get; set; } = 16384;
    [JsonPropertyName("defaultProjectPath")] public string? DefaultProjectPath { get; set; }

    [JsonPropertyName("createdAt")]
    [JsonConverter(typeof(AppleDateConverter))]
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;

    [JsonPropertyName("lastLaunchedAt")]
    [JsonConverter(typeof(NullableAppleDateConverter))]
    public DateTime? LastLaunchedAt { get; set; }

    [JsonPropertyName("isPinned")] public bool IsPinned { get; set; }
    [JsonPropertyName("isSystem")] public bool IsSystem { get; set; }

    public CursorProfile Copy() => (CursorProfile)MemberwiseClone();

    /// <summary>Normalize legacy/unknown app values to cursor.</summary>
    [JsonIgnore]
    public string NormalizedApp => NormalizeApp(App);

    [JsonIgnore]
    public string AppLabel => LabelFor(App);

    [JsonIgnore]
    public string AppBadge => NormalizedApp switch
    {
        AppClaudeCode => "CODE",
        AppClaudeDesktop => "DESKTOP",
        AppGrokBot => "GROK",
        _ => "",
    };

    [JsonIgnore]
    public bool ShowAppBadge => NormalizedApp != AppCursor;

    /// <summary>Only Cursor launches with --max-memory.</summary>
    [JsonIgnore]
    public bool HasMemoryCap => NormalizedApp == AppCursor;

    /// <summary>Whether launching can open a project folder (Cursor, Claude Code).</summary>
    [JsonIgnore]
    public bool OpensProjectFolder => NormalizedApp is AppCursor or AppClaudeCode;

    /// <summary>Cursor and Claude Code duplicates are full clones (same login);
    /// Desktop and Grok Bot copies are always overflow accounts.</summary>
    [JsonIgnore]
    public bool ClonesWholeProfile => NormalizedApp is AppCursor or AppClaudeCode;

    /// <summary>Sentence-case label for "copy into a second account".</summary>
    [JsonIgnore]
    public string CopyActionTitle => NormalizedApp == AppGrokBot
        ? "Copy settings to a new profile" : "New overflow account from this";

    [JsonIgnore]
    public string MemoryCapLabel => DefaultMemoryMB >= 1024
        ? $"{DefaultMemoryMB / 1024.0:0} GB" : $"{DefaultMemoryMB} MB";

    /// <summary>Display name for a one-click copy of this profile.</summary>
    [JsonIgnore]
    public string CopyName => (IsSystem ? AppLabel : DisplayName)
        + (NormalizedApp == AppGrokBot ? " 2" : " Overflow");

    public static string SystemMarkerFor(string app) => NormalizeApp(app) switch
    {
        AppClaudeCode => SystemCodeFolderName,
        AppClaudeDesktop => SystemDesktopFolderName,
        AppGrokBot => SystemGrokFolderName,
        _ => SystemFolderName,
    };

    public static string SystemDisplayNameFor(string app) => NormalizeApp(app) switch
    {
        AppClaudeCode => "Main Claude Code",
        AppClaudeDesktop => "Main Claude Desktop",
        AppGrokBot => "Main Grok Bot",
        _ => "Main Cursor",
    };
}

/// <summary>
/// The macOS app writes dates with Swift's default JSONEncoder strategy:
/// seconds since 2001-01-01 UTC. Match it so .profiles.json is portable.
/// </summary>
public class AppleDateConverter : JsonConverter<DateTime>
{
    private static readonly DateTime Reference = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    public override DateTime Read(ref Utf8JsonReader reader, Type t, JsonSerializerOptions o) =>
        Reference.AddSeconds(reader.GetDouble());

    public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions o) =>
        writer.WriteNumberValue((value.ToUniversalTime() - Reference).TotalSeconds);
}

public class NullableAppleDateConverter : JsonConverter<DateTime?>
{
    private static readonly DateTime Reference = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    public override DateTime? Read(ref Utf8JsonReader reader, Type t, JsonSerializerOptions o) =>
        reader.TokenType == JsonTokenType.Null ? null : Reference.AddSeconds(reader.GetDouble());

    public override void Write(Utf8JsonWriter writer, DateTime? value, JsonSerializerOptions o)
    {
        if (value is null) writer.WriteNullValue();
        else writer.WriteNumberValue((value.Value.ToUniversalTime() - Reference).TotalSeconds);
    }
}

public static class Palette
{
    public static readonly (string Name, string Hex)[] All =
    {
        ("Indigo", "#6366F1"), ("Violet", "#8B5CF6"), ("Fuchsia", "#D946EF"),
        ("Rose", "#F43F5E"), ("Orange", "#F97316"), ("Amber", "#F59E0B"),
        ("Emerald", "#10B981"), ("Teal", "#14B8A6"), ("Sky", "#0EA5E9"),
        ("Blue", "#3B82F6"), ("Slate", "#64748B"), ("Lime", "#84CC16"),
    };

    public static string RandomHex() => All[Random.Shared.Next(All.Length)].Hex;

    public static Color ColorFromHex(string hex)
    {
        try { return (Color)ColorConverter.ConvertFromString(hex); }
        catch { return (Color)ColorConverter.ConvertFromString("#6366F1"); }
    }

    /// <summary>Same hex parsing, but as a GDI+ color for icon rendering.</summary>
    public static System.Drawing.Color ColorFromHexGdi(string hex)
    {
        var c = ColorFromHex(hex);
        return System.Drawing.Color.FromArgb(c.A, c.R, c.G, c.B);
    }
}

public static class Format
{
    public static string Bytes(long? bytes)
    {
        if (bytes is null) return "…";
        double b = bytes.Value;
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        int i = 0;
        while (b >= 1024 && i < units.Length - 1) { b /= 1024; i++; }
        return $"{b:0.#} {units[i]}";
    }

    public static string Relative(DateTime? utc)
    {
        if (utc is null) return "never launched";
        var span = DateTime.UtcNow - utc.Value.ToUniversalTime();
        if (span.TotalSeconds < 90) return "just now";
        if (span.TotalMinutes < 60) return $"{(int)span.TotalMinutes}m ago";
        if (span.TotalHours < 24) return $"{(int)span.TotalHours}h ago";
        if (span.TotalDays < 30) return $"{(int)span.TotalDays}d ago";
        return utc.Value.ToLocalTime().ToString("d MMM yyyy");
    }
}

public static class ProfileNaming
{
    public static string SanitizeFolderName(string raw) =>
        new(raw.Where(c => char.IsLetterOrDigit(c) || c is '_' or '-').ToArray());
}

/// <summary>App settings stored beside the profiles (equivalent of UserDefaults on macOS).</summary>
public class LauncherSettings
{
    [JsonPropertyName("customCursorPath")] public string CustomCursorPath { get; set; } = "";
    [JsonPropertyName("customCodePath")] public string CustomCodePath { get; set; } = "";
    [JsonPropertyName("customDesktopPath")] public string CustomDesktopPath { get; set; } = "";
    [JsonPropertyName("customGrokPath")] public string CustomGrokPath { get; set; } = "";
    /// <summary>Brainium checkout (or bin/brainium.mjs); empty = auto-detect.</summary>
    [JsonPropertyName("brainiumPath")] public string BrainiumPath { get; set; } = "";
    /// <summary>node.exe for Brainium; empty = auto-detect.</summary>
    [JsonPropertyName("brainiumNodePath")] public string BrainiumNodePath { get; set; } = "";
    /// <summary>Wire new profiles into the second brain as they're created.</summary>
    [JsonPropertyName("brainAutoWire")] public bool BrainAutoWire { get; set; }
    [JsonPropertyName("defaultMemoryMB")] public int DefaultMemoryMB { get; set; } = 16384;
    /// <summary>App theme: "system" (follow Windows), "light" or "dark".</summary>
    [JsonPropertyName("theme")] public string Theme { get; set; } = "system";

    public static string PathFor(string profilesDir) => Path.Combine(profilesDir, ".launcher-settings.json");

    public static LauncherSettings Load(string profilesDir)
    {
        try
        {
            var path = PathFor(profilesDir);
            if (File.Exists(path))
                return JsonSerializer.Deserialize<LauncherSettings>(File.ReadAllText(path)) ?? new();
        }
        catch { /* fall through to defaults */ }
        return new();
    }

    public void Save(string profilesDir)
    {
        try
        {
            Directory.CreateDirectory(profilesDir);
            File.WriteAllText(PathFor(profilesDir),
                JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* non-fatal */ }
    }
}
