using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace CursorProfiles;

/// <summary>
/// A running Cursor window's taskbar icon can't be rebranded (re-signing
/// Cursor's own executable under a different identity crashes it — this is
/// deliberate anti-tamper protection, confirmed against a real install), so
/// the next best way to tell profiles apart while they're open is a distinct
/// title bar color per profile, visible in the window itself and Alt+Tab.
/// </summary>
public static class TitleBarColorizer
{
    /// <summary>Merge this profile's title-bar colors into its
    /// User/settings.json, preserving every other setting already there.
    /// No-op for the built-in profile — the user's real settings are never touched.</summary>
    public static void Apply(CursorProfile profile, string profileDir)
    {
        if (profile.IsSystem) return;

        var userDir = Path.Combine(profileDir, "User");
        Directory.CreateDirectory(userDir);
        var settingsPath = Path.Combine(userDir, "settings.json");

        var settings = ReadSettings(settingsPath);

        var colors = settings["workbench.colorCustomizations"] as JsonObject ?? new JsonObject();
        foreach (var (key, value) in ColorValues(profile.ColorHex))
            colors[key] = value;
        settings["workbench.colorCustomizations"] = colors;
        // The default title bar ignores colorCustomizations — required for the colors to render.
        settings["window.titleBarStyle"] = "custom";

        File.WriteAllText(settingsPath, settings.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    public static Dictionary<string, string> ColorValues(string hex)
    {
        var foreground = ContrastingForeground(hex);
        return new()
        {
            ["titleBar.activeBackground"] = hex,
            ["titleBar.activeForeground"] = foreground,
            ["titleBar.inactiveBackground"] = Shade(hex, 0.55),
            ["titleBar.inactiveForeground"] = foreground + "AA",
        };
    }

    // MARK: JSONC-tolerant read

    private static JsonObject ReadSettings(string path)
    {
        if (!File.Exists(path)) return new JsonObject();
        try
        {
            var stripped = StripJsonComments(File.ReadAllText(path));
            return JsonNode.Parse(stripped) as JsonObject ?? new JsonObject();
        }
        catch (JsonException)
        {
            return new JsonObject(); // unparsable settings.json — start fresh rather than fail the launch
        }
    }

    /// <summary>Strips // and /* */ comments and trailing commas so a
    /// hand-edited JSONC settings.json (VS Code allows both) round-trips
    /// through strict JSON parsing. Comments are not preserved on write.</summary>
    private static string StripJsonComments(string text)
    {
        var sb = new System.Text.StringBuilder(text.Length);
        bool inString = false, escaped = false;
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (inString)
            {
                sb.Append(c);
                if (escaped) escaped = false;
                else if (c == '\\') escaped = true;
                else if (c == '"') inString = false;
                continue;
            }
            if (c == '"') { inString = true; sb.Append(c); continue; }
            if (c == '/' && i + 1 < text.Length)
            {
                if (text[i + 1] == '/')
                {
                    while (i < text.Length && text[i] != '\n') i++;
                    i--;
                    continue;
                }
                if (text[i + 1] == '*')
                {
                    i += 2;
                    while (i + 1 < text.Length && !(text[i] == '*' && text[i + 1] == '/')) i++;
                    i++;
                    continue;
                }
            }
            sb.Append(c);
        }
        return Regex.Replace(sb.ToString(), @",\s*([}\]])", "$1");
    }

    // MARK: Color helpers

    private static string Shade(string hex, double factor)
    {
        if (!uint.TryParse(hex.TrimStart('#'), System.Globalization.NumberStyles.HexNumber, null, out var value))
            return hex;
        var r = (int)(((value >> 16) & 0xFF) * factor);
        var g = (int)(((value >> 8) & 0xFF) * factor);
        var b = (int)((value & 0xFF) * factor);
        return $"#{r:X2}{g:X2}{b:X2}";
    }

    private static string ContrastingForeground(string hex)
    {
        if (!uint.TryParse(hex.TrimStart('#'), System.Globalization.NumberStyles.HexNumber, null, out var value))
            return "#FFFFFF";
        double r = (value >> 16) & 0xFF, g = (value >> 8) & 0xFF, b = value & 0xFF;
        var luminance = 0.299 * r + 0.587 * g + 0.114 * b;
        return luminance > 150 ? "#1A1A1A" : "#FFFFFF";
    }
}
