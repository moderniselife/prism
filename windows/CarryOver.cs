using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CursorProfiles;

/// <summary>
/// Overflow accounts for every app: a new profile that carries another
/// profile's agents and config over, but never its identity. The new
/// profile always starts signed out and you sign in with a different
/// account on first launch.
///
/// Rules are allowlists wherever the app mixes config and identity
/// (Cursor, Claude Code, Claude Desktop): anything not listed stays behind,
/// so an unknown new token file can never leak. Grok Bot keeps them in
/// separate trees, so its rule is a denylist over the agent data root.
///
/// Keep in sync with tui/carryover.go, tui/grokbot.go and
/// Sources/CursorProfiles/CarryOver.swift.
/// </summary>
public static class CarryOver
{
    /// <summary>Settings, keybindings, tasks and snippets. Login tokens and
    /// the machine id stay behind; extensions are already shared.</summary>
    public static readonly string[] Cursor =
        { "User/settings.json", "User/keybindings.json", "User/tasks.json", "User/snippets" };

    /// <summary>MCP servers/preferences and installed extensions.</summary>
    public static readonly string[] Desktop =
        { "claude_desktop_config.json", "Claude Extensions", "Claude Extensions Settings" };

    /// <summary>Everything that shapes how Claude Code works for you.
    /// Credentials, history, todos, shell snapshots and caches stay behind.</summary>
    public static readonly string[] ClaudeCode =
        { "settings.json", "CLAUDE.md", "keybindings.json", "agents", "commands",
          "skills", "output-styles", "hooks", "plugins" };

    /// <summary>The preference / user-scoped MCP parts of .claude.json.</summary>
    public static readonly string[] ClaudeCodeStateKeys =
        { "mcpServers", "theme", "editorMode", "autoCompactEnabled", "verbose", "preferredNotifChannel" };

    /// <summary>Grok Bot data-root entries bound to an account, a machine or a
    /// running instance (exact name, or name + "." for temp/backup files).</summary>
    public static readonly string[] GrokSkipTop =
    {
        ".grokbot-data-root-v1", "host.lock", "host-token.json", "host-secrets.json",
        "gateway.json", "gateway-descriptor.json", "mcp-auth.json", "onepassword-oauth-states.json",
        "local-tool-spent-sends.json", "local-tool-retirements.json", "local-cua-helper.json",
        "recreate-intent.json", "recreate-resume.json", "desktop-status.json", "kept-update.json",
        "dev-box", "computer-use", "logs", "v8-code-cache",
    };

    public static readonly string[] GrokSkipTopPrefixes = { "local-exec-" };

    /// <summary>settings.json fields bound to the signed-in Grok account.</summary>
    public static readonly string[] GrokAccountSettingsKeys =
        { "activeAccountScope", "hasSeenOnboardingAccountScope", "hasSeenOnboarding",
          "boxRosterCensus", "egressTunnelCommittedBoxUrls" };

    /// <summary>Lock and socket files never travel, at any depth.</summary>
    public static bool SkipAnywhere(string name)
    {
        var lower = name.ToLowerInvariant();
        if (lower is "lockfile" or "singletonlock" or "singletonsocket" or "singletoncookie") return true;
        return lower.EndsWith(".lock") || lower.EndsWith(".sock") || lower.EndsWith(".pid");
    }

    /// <summary>Whether a Grok data-root entry (slash-separated, relative) stays behind.</summary>
    public static bool GrokSkips(string rel)
    {
        var parts = rel.Split('/');
        if (SkipAnywhere(parts[^1])) return true;
        var top = parts[0];
        if (GrokSkipTop.Any(n => top == n || top.StartsWith(n + ".", StringComparison.Ordinal))) return true;
        return GrokSkipTopPrefixes.Any(p => top.StartsWith(p, StringComparison.Ordinal));
    }

    /// <summary>.claude.json for a Claude Code config dir: inside it when
    /// CLAUDE_CONFIG_DIR points there, in the home folder otherwise.</summary>
    public static string ClaudeCodeStateFile(string configDir, bool isSystem)
    {
        if (isSystem && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR")))
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude.json");
        return Path.Combine(configDir, ".claude.json");
    }

    /// <summary>Copy source's agents and config into dstDir (a new profile
    /// of the same app). Returns files copied.</summary>
    public static int Run(string app, string srcDir, bool srcIsSystem, string dstDir) =>
        CursorProfile.NormalizeApp(app) switch
        {
            CursorProfile.AppGrokBot => GrokData(GrokLauncher.DataRoot(srcDir, srcIsSystem),
                                                 GrokLauncher.DataRoot(dstDir, false)),
            CursorProfile.AppClaudeCode => ClaudeCodeConfig(srcDir, ClaudeCodeStateFile(srcDir, srcIsSystem), dstDir),
            CursorProfile.AppClaudeDesktop => Allowlist(srcDir, dstDir, Desktop),
            _ => Allowlist(srcDir, dstDir, Cursor),
        };

    public static int Allowlist(string srcDir, string dstDir, IEnumerable<string> entries)
    {
        if (!Directory.Exists(srcDir))
            throw new IOException($"Nothing to carry over: {srcDir} does not exist.");
        var total = 0;
        foreach (var rel in entries)
        {
            var src = Path.Combine(srcDir, rel.Replace('/', Path.DirectorySeparatorChar));
            if (!File.Exists(src) && !Directory.Exists(src)) continue;
            total += CopyTree(src, Path.Combine(dstDir, rel.Replace('/', Path.DirectorySeparatorChar)));
        }
        return total;
    }

    /// <summary>Copy a file or folder, skipping links/reparse points and lock files.</summary>
    public static int CopyTree(string src, string dst)
    {
        var attrs = File.GetAttributes(src);
        if (attrs.HasFlag(FileAttributes.ReparsePoint)) return 0;
        if (!attrs.HasFlag(FileAttributes.Directory))
        {
            if (SkipAnywhere(Path.GetFileName(src))) return 0;
            Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
            File.Copy(src, dst, overwrite: true);
            return 1;
        }
        Directory.CreateDirectory(dst);
        var copied = 0;
        foreach (var entry in Directory.EnumerateFileSystemEntries(src))
        {
            if (SkipAnywhere(Path.GetFileName(entry))) continue;
            copied += CopyTree(entry, Path.Combine(dst, Path.GetFileName(entry)));
        }
        return copied;
    }

    public static int ClaudeCodeConfig(string srcDir, string srcStateFile, string dstDir)
    {
        var n = Allowlist(srcDir, dstDir, ClaudeCode);
        RewritePluginPaths(Path.Combine(dstDir, "plugins"), srcDir, dstDir);
        if (CopyClaudeState(srcStateFile, Path.Combine(dstDir, ".claude.json"))) n++;
        return n;
    }

    /// <summary>Write only the allowlisted keys of .claude.json.</summary>
    public static bool CopyClaudeState(string src, string dst)
    {
        if (!File.Exists(src)) return false;
        var all = JsonNode.Parse(File.ReadAllText(src)) as JsonObject
            ?? throw new IOException($"Could not read {src}.");
        var kept = new JsonObject();
        foreach (var key in ClaudeCodeStateKeys)
            if (all.TryGetPropertyValue(key, out var value))
                kept[key] = value?.DeepClone();
        if (kept.Count == 0) return false;
        File.WriteAllText(dst, kept.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + "\n");
        return true;
    }

    /// <summary>Claude Code records absolute install paths in plugins/*.json:
    /// point the copies at the new profile.</summary>
    public static void RewritePluginPaths(string pluginsDir, string srcDir, string dstDir)
    {
        if (!Directory.Exists(pluginsDir)) return;
        // JSON escapes backslashes, so Windows paths appear doubled inside files.
        string Escape(string s) => JsonSerializer.Serialize(s)[1..^1];
        var pairs = new List<(string from, string to)> { (srcDir, dstDir) };
        if (Escape(srcDir) != srcDir) pairs.Add((Escape(srcDir), Escape(dstDir)));
        foreach (var file in Directory.EnumerateFiles(pluginsDir, "*.json", SearchOption.AllDirectories))
        {
            var text = File.ReadAllText(file);
            var output = text;
            foreach (var (from, to) in pairs)
                output = output.Replace(from, to, StringComparison.Ordinal);
            if (output != text) File.WriteAllText(file, output);
        }
    }

    /// <summary>Copy Grok Bot agents and config, leaving identity, credentials
    /// and runtime state behind, and scrub settings.json's account keys.</summary>
    public static int GrokData(string srcRoot, string dstRoot)
    {
        if (!Directory.Exists(srcRoot))
            throw new IOException($"Nothing to carry over: {srcRoot} does not exist.");
        Directory.CreateDirectory(dstRoot);
        var copied = GrokWalk(srcRoot, srcRoot, dstRoot);
        ScrubGrokSettings(Path.Combine(dstRoot, "settings.json"));
        return copied;
    }

    private static int GrokWalk(string root, string dir, string dstRoot)
    {
        var copied = 0;
        foreach (var entry in Directory.EnumerateFileSystemEntries(dir))
        {
            var rel = Path.GetRelativePath(root, entry).Replace(Path.DirectorySeparatorChar, '/');
            if (GrokSkips(rel)) continue;
            var attrs = File.GetAttributes(entry);
            if (attrs.HasFlag(FileAttributes.ReparsePoint)) continue;
            var target = Path.Combine(dstRoot, rel.Replace('/', Path.DirectorySeparatorChar));
            if (attrs.HasFlag(FileAttributes.Directory))
            {
                Directory.CreateDirectory(target);
                copied += GrokWalk(root, entry, dstRoot);
            }
            else
            {
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                File.Copy(entry, target, overwrite: true);
                copied++;
            }
        }
        return copied;
    }

    /// <summary>Drop account-bound keys from a copied settings.json; an
    /// unreadable file is removed rather than carried unvetted.</summary>
    public static void ScrubGrokSettings(string path)
    {
        if (!File.Exists(path)) return;
        JsonObject? all;
        try { all = JsonNode.Parse(File.ReadAllText(path)) as JsonObject; }
        catch (JsonException) { all = null; }
        if (all is null)
        {
            File.Delete(path);
            return;
        }
        foreach (var key in GrokAccountSettingsKeys) all.Remove(key);
        File.WriteAllText(path, all.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + "\n");
    }
}
