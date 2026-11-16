using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows;

namespace CursorProfiles;

public enum BrainSetupStep { None, Brainium, Node }

/// <summary>
/// Second brain state and actions for the UI. Every CLI call runs off the
/// UI thread and reports back a one-line message.
/// </summary>
public sealed class BrainService : INotifyPropertyChanged
{
    private readonly ProfileStore _store;
    private BrainiumBridge.Status? _status;
    private bool _busy;
    private string? _message;
    private BrainSetupStep _setupStep;

    public BrainService(ProfileStore store) => _store = store;

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Raise([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public BrainiumBridge.Status? Status
    {
        get => _status;
        private set { _status = value; Raise(); Raise(nameof(IsOn)); Raise(nameof(CardDetail)); }
    }

    public bool Busy { get => _busy; private set { _busy = value; Raise(); } }
    public string? Message { get => _message; set { _message = value; Raise(); } }
    public BrainSetupStep SetupStep { get => _setupStep; private set { _setupStep = value; Raise(); } }

    public bool IsOn => Status?.PersonalExists == true;

    /// <summary>One line for the sidebar card.</summary>
    public string CardDetail
    {
        get
        {
            if (Status is not { } s) return "Not set up";
            if (!s.PersonalExists || string.IsNullOrEmpty(s.PersonalBrain)) return "No personal brain yet";
            var place = $"Saving to {Tilde(s.PersonalBrain)}";
            return s.Pending > 0 ? $"{s.Pending} to file · {place}" : place;
        }
    }

    public string? CliPath => BrainiumBridge.FindCli(_store.Settings.BrainiumPath);
    public string? NodePath => BrainiumBridge.FindNode(_store.Settings.BrainiumNodePath);
    public BrainiumBridge? Bridge => BrainiumBridge.Resolve(_store.Settings.BrainiumPath, _store.Settings.BrainiumNodePath);

    public static string Tilde(string path)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return path.StartsWith(home, StringComparison.OrdinalIgnoreCase) ? "~" + path[home.Length..] : path;
    }

    private static void OnUi(Action action)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess()) action();
        else dispatcher.Invoke(action);
    }

    public void RefreshStatus()
    {
        if (Bridge is not { } bridge)
        {
            Status = null;
            return;
        }
        Task.Run(() => { try { return bridge.GetStatus(); } catch { return null; } })
            .ContinueWith(t => OnUi(() => Status = t.Result));
    }

    /// <summary>Run work against the CLI off the UI thread.</summary>
    private void Run(string label, Func<BrainiumBridge, string> work, Action<string>? onSuccess = null)
    {
        if (Bridge is not { } bridge)
        {
            Message = BrainiumBridge.NotFoundMessage;
            Status = null;
            return;
        }
        Busy = true;
        Task.Run(() =>
        {
            try { return (ok: true, text: work(bridge)); }
            catch (Exception e) { return (ok: false, text: e.Message); }
        }).ContinueWith(t => OnUi(() =>
        {
            Busy = false;
            if (t.Result.ok)
            {
                if (onSuccess is not null) onSuccess(t.Result.text);
                else Message = t.Result.text;
            }
            else Message = $"{label}: {t.Result.text}";
            RefreshStatus();
        }));
    }

    private IEnumerable<(string App, string Dir, bool IsSystem)> Targets(IEnumerable<ProfileVM> profiles) =>
        profiles.Select(p => (p.Model.NormalizedApp, _store.DirectoryFor(p.Model), p.Model.IsSystem)).ToList();

    public void CreatePersonalBrain(string path) =>
        Run("Couldn't create the personal brain", b =>
        {
            b.Run("init-personal", path);
            return $"Personal brain ready at {Tilde(path)}.";
        });

    /// <summary>config set for each pair, in order, in one task (the config
    /// file is read-modify-written). Re-wires Claude Code profiles when
    /// capture changes so their hooks follow the switch.</summary>
    public void SetConfig(IReadOnlyList<(string Key, string Value)> pairs)
    {
        var changesCapture = pairs.Any(p => p.Key == "capture");
        var targets = changesCapture
            ? Targets(_store.Profiles.Where(p => p.Model.NormalizedApp == CursorProfile.AppClaudeCode)).ToList()
            : new List<(string, string, bool)>();
        Run("Couldn't save the setting", b =>
        {
            foreach (var (key, value) in pairs) b.Run("config", "set", key, value);
            if (targets.Count > 0) b.WireAll(targets, true);
            return "Saved.";
        });
    }

    public void WireAll(bool enable = true)
    {
        var targets = Targets(_store.Profiles).ToList();
        Run(enable ? "Wiring failed" : "Unwiring failed", b => b.WireAll(targets, enable));
    }

    /// <summary>Wire one profile now (nothing to do for Grok Bot).</summary>
    public void WireProfile(ProfileVM vm)
    {
        if (BrainiumBridge.WireArguments(vm.Model.NormalizedApp, "", false, false) is null) return;
        var target = Targets(new[] { vm }).ToList();
        var name = vm.Model.DisplayName;
        Run($"Couldn't wire '{name}'", b =>
        {
            b.WireAll(target, true);
            return $"Wired '{name}' into your second brain.";
        });
    }

    public void WireIfEnabled(ProfileVM vm)
    {
        if (_store.Settings.BrainAutoWire && Bridge is not null) WireProfile(vm);
    }

    /// <summary>Copy the Grok Bot instructions snippet to the clipboard.</summary>
    public void CopyGrokSnippet() =>
        Run("Couldn't build the snippet", b => b.Run("snippet", "grok"), text =>
        {
            try { Clipboard.SetText(text); } catch { /* clipboard busy */ }
            Message = "Grok Bot snippet copied. Paste it into the agent's instructions.";
        });

    // MARK: Setup

    private void RunSetup(BrainSetupStep step, string label, Func<Task<string>> work)
    {
        SetupStep = step;
        Message = null;
        Task.Run(async () =>
        {
            try { return (ok: true, text: await work()); }
            catch (Exception e) { return (ok: false, text: e.Message); }
        }).ContinueWith(t => OnUi(() =>
        {
            SetupStep = BrainSetupStep.None;
            Message = t.Result.ok ? t.Result.text : $"{label}: {t.Result.text}";
            Raise(nameof(CliPath));
            Raise(nameof(NodePath));
            RefreshStatus();
        }));
    }

    public void InstallBrainium() =>
        RunSetup(BrainSetupStep.Brainium, "Couldn't install Brainium", () => BrainiumSetup.InstallBrainiumAsync());

    public void UpdateBrainium(string dir) =>
        RunSetup(BrainSetupStep.Brainium, "Couldn't update Brainium", () => Task.FromResult(BrainiumSetup.UpdateBrainium(dir)));

    public void InstallNode() =>
        RunSetup(BrainSetupStep.Node, "Couldn't install Node.js", BrainiumSetup.InstallNodeAsync);

    public void Recheck()
    {
        Raise(nameof(CliPath));
        Raise(nameof(NodePath));
        RefreshStatus();
    }

    public bool UseBrainiumFolder(string folder)
    {
        if (BrainiumBridge.FindCli(folder) is null)
        {
            Message = "That folder doesn't contain bin\\brainium.mjs.";
            return false;
        }
        _store.Settings.BrainiumPath = folder;
        _store.Settings.Save(_store.ProfilesDir);
        Recheck();
        return true;
    }

    public void UseNode(string path)
    {
        _store.Settings.BrainiumNodePath = path;
        _store.Settings.Save(_store.ProfilesDir);
        Recheck();
    }

    public static bool IsGitCheckout(string dir) => Directory.Exists(Path.Combine(dir, ".git"));
}
