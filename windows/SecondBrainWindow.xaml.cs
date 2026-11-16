using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;

namespace CursorProfiles;

/// <summary>Settings → Second brain: set up Brainium and Node.js, the
/// personal brain, profile wiring and the capture summarizer.</summary>
public partial class SecondBrainWindow : Window
{
    private readonly ProfileStore _store;
    private BrainService Brain => _store.Brain;
    private bool _syncing;

    public SecondBrainWindow(ProfileStore store)
    {
        InitializeComponent();
        ThemeManager.ApplyChrome(this);
        _store = store;
        foreach (var (id, label) in BrainiumBridge.Providers)
            ProviderBox.Items.Add(new ComboBoxItem { Content = label, Tag = id });
        AutoWireBox.IsChecked = store.Settings.BrainAutoWire;
        Brain.PropertyChanged += OnBrainChanged;
        Closed += (_, _) => Brain.PropertyChanged -= OnBrainChanged;
        SyncFromStatus();
        RefreshUi();
        Brain.RefreshStatus();
    }

    private void OnBrainChanged(object? sender, PropertyChangedEventArgs e) =>
        Dispatcher.Invoke(() =>
        {
            if (e.PropertyName == nameof(BrainService.Status)) SyncFromStatus();
            RefreshUi();
        });

    private string SelectedProvider => (ProviderBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "agent";
    private bool UsesApi => SelectedProvider is not ("agent" or "none");

    /// <summary>Self-hosted servers have no default address.</summary>
    private bool NeedsUrl
    {
        get
        {
            if (SelectedProvider is not ("bonsai" or "openai-compatible") || UrlBox.Text.Trim().Length > 0)
                return false;
            var s = Brain.Status?.Summarizer;
            return s?.Provider != SelectedProvider || string.IsNullOrEmpty(s?.Url);
        }
    }

    private void SyncFromStatus()
    {
        _syncing = true;
        var s = Brain.Status;
        CaptureBox.IsChecked = s?.Capture ?? false;
        var provider = s?.Summarizer?.Provider ?? "agent";
        foreach (ComboBoxItem item in ProviderBox.Items)
            if ((string)item.Tag == provider) ProviderBox.SelectedItem = item;
        if (ProviderBox.SelectedItem is null) ProviderBox.SelectedIndex = 0;
        // Show only what the user set, not provider defaults.
        UrlBox.Text = "";
        ModelBox.Text = "";
        KeyEnvBox.Text = "";
        KeyBox.Password = "";
        _syncing = false;
    }

    private void RefreshUi()
    {
        var cli = Brain.CliPath;
        var node = Brain.NodePath;
        var ready = Brain.Bridge is not null;

        BuildSetupRow(CliText, CliButtons, cli is null ? null : BrainiumBridge.CheckoutDir(cli), BrainSetupStep.Brainium);
        BuildSetupRow(NodeText, NodeButtons, node, BrainSetupStep.Node);
        SetupHintRow.Visibility = cli is null || node is null ? Visibility.Visible : Visibility.Collapsed;
        SetupHint.Text = (cli is null, node is null) switch
        {
            (true, true) => "Brainium runs on Node.js. Install both, or point Prism at copies you already have.",
            (false, true) => BrainiumSetup.Winget is not null
                ? "Brainium needs Node.js 18 or newer. Install uses winget."
                : "Brainium needs Node.js 18 or newer. Install downloads the official installer from nodejs.org.",
            _ => BrainiumSetup.Git is not null
                ? "Install clones Brainium from GitHub into your home folder."
                : "Install downloads Brainium from GitHub into your home folder.",
        };

        var s = Brain.Status;
        var hasPersonal = s?.PersonalExists == true;
        PersonalText.Text = hasPersonal ? BrainService.Tilde(s!.PersonalBrain ?? "") : "Not created yet";
        PersonalButton.Content = hasPersonal ? "Change…" : "Create…";
        PersonalButton.IsEnabled = ready && !Brain.Busy;
        PersonalTip.Visibility = hasPersonal && string.IsNullOrEmpty(s!.PersonalRemote) ? Visibility.Visible : Visibility.Collapsed;

        WireButtons.IsEnabled = ready && !Brain.Busy;
        CaptureBox.IsEnabled = ready && !Brain.Busy;

        ApiFields.Visibility = UsesApi ? Visibility.Visible : Visibility.Collapsed;
        ProviderHelp.Text = ProviderHelpText(SelectedProvider);
        UrlBox.ToolTip = SelectedProvider switch
        {
            "anthropic" => "https://api.anthropic.com",
            "openai" => "https://api.openai.com/v1",
            "bonsai" => "Your Bonsai server, e.g. http://<host>:<port>/v1",
            _ => "http://<host>:<port>/v1",
        };
        KeyHint.Text = s?.Summarizer?.HasKey == true ? "A key is saved. Leave empty to keep it." : "Optional if the env var is set.";
        UrlWarning.Visibility = UsesApi && NeedsUrl ? Visibility.Visible : Visibility.Collapsed;
        UrlWarning.Text = SelectedProvider == "bonsai"
            ? "Enter your Bonsai server's URL: its OpenAI-compatible API, usually ending in /v1."
            : "Enter the server's OpenAI-compatible base URL, usually ending in /v1.";
        SaveSummarizer.IsEnabled = ready && !Brain.Busy && !NeedsUrl;

        BusyBar.Visibility = Brain.Busy || Brain.SetupStep != BrainSetupStep.None ? Visibility.Visible : Visibility.Collapsed;
        var pending = s?.Pending ?? 0;
        MessageText.Text = string.Join("  ·  ", new[]
        {
            Brain.Message ?? "",
            pending > 0 ? $"{pending} capture{(pending == 1 ? "" : "s")} waiting" : "",
        }.Where(t => t.Length > 0));
    }

    /// <summary>Found: path + Change… (+ Update for a git checkout).
    /// Missing: Install + Use existing…. Installing: a note.</summary>
    private void BuildSetupRow(TextBlock text, StackPanel buttons, string? found, BrainSetupStep step)
    {
        buttons.Children.Clear();
        Button Add(string label, Style style, RoutedEventHandler click)
        {
            var b = new Button { Content = label, Style = style, Margin = new Thickness(8, 0, 0, 0) };
            b.Click += click;
            buttons.Children.Add(b);
            return b;
        }

        if (Brain.SetupStep == step)
        {
            text.Text = step == BrainSetupStep.Brainium ? "Installing…" : "Installing Node.js…";
            text.SetResourceReference(ForegroundProperty, "MutedBrush");
            return;
        }
        var busy = Brain.SetupStep != BrainSetupStep.None;
        if (found is not null)
        {
            text.Text = "✓  " + BrainService.Tilde(found);
            text.ToolTip = found;
            text.SetResourceReference(ForegroundProperty, "SubTextBrush");
            if (step == BrainSetupStep.Brainium && BrainService.IsGitCheckout(found))
                Add("Update", (Style)FindResource("QuietButton"), (_, _) => Brain.UpdateBrainium(found)).IsEnabled = !busy;
            Add("Change…", (Style)FindResource("SecondaryButton"), (_, _) => UseExisting(step));
        }
        else
        {
            text.Text = "Not installed";
            text.ToolTip = null;
            text.SetResourceReference(ForegroundProperty, "MutedBrush");
            Add("Install", (Style)FindResource("PrimaryButton"), (_, _) =>
            {
                if (step == BrainSetupStep.Brainium) Brain.InstallBrainium();
                else Brain.InstallNode();
            }).IsEnabled = !busy;
            Add("Use existing…", (Style)FindResource("SecondaryButton"), (_, _) => UseExisting(step));
        }
    }

    private void UseExisting(BrainSetupStep step)
    {
        if (step == BrainSetupStep.Brainium)
        {
            var dialog = new Microsoft.Win32.OpenFolderDialog
            {
                Title = "Choose your Brainium folder (the one containing bin\\brainium.mjs)",
                InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            };
            if (dialog.ShowDialog(this) == true) Brain.UseBrainiumFolder(dialog.FolderName);
        }
        else
        {
            var dialog = new Microsoft.Win32.OpenFileDialog
            {
                Title = "Choose node.exe",
                Filter = "Node.js|node.exe|Executables|*.exe",
                InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            };
            if (dialog.ShowDialog(this) == true) Brain.UseNode(dialog.FileName);
        }
        RefreshUi();
    }

    private static string ProviderHelpText(string provider) => provider switch
    {
        "agent" => "Your own AI files captured sessions itself through the Brainium MCP server: no extra API calls or tokens.",
        "none" => "Files a plain mechanical summary (prompts, files, commands). No AI involved.",
        "anthropic" => "Uses the Anthropic Messages API. Default model claude-haiku-5-5; key from ANTHROPIC_API_KEY unless you save one.",
        "openai" => "Uses the OpenAI Chat Completions API. Set a model; key from OPENAI_API_KEY unless you save one.",
        "bonsai" => "Uses your self-hosted Bonsai server through its OpenAI-compatible API. Enter its URL below; default model solo-quick.",
        _ => "Any OpenAI-compatible endpoint: set its base URL (ending in /v1 where needed) and model.",
    };

    private void CheckAgain_Click(object sender, RoutedEventArgs e) => Brain.Recheck();

    private void PersonalBrain_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog
        {
            Title = "Pick an empty folder (or an existing personal brain)",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        };
        if (dialog.ShowDialog(this) == true) Brain.CreatePersonalBrain(dialog.FolderName);
    }

    private void AutoWire_Click(object sender, RoutedEventArgs e)
    {
        _store.Settings.BrainAutoWire = AutoWireBox.IsChecked == true;
        _store.Settings.Save(_store.ProfilesDir);
    }

    private void Capture_Click(object sender, RoutedEventArgs e)
    {
        if (_syncing) return;
        var on = CaptureBox.IsChecked == true;
        if (on != (Brain.Status?.Capture ?? false))
            Brain.SetConfig(new[] { ("capture", on ? "true" : "false") });
    }

    private void WireAll_Click(object sender, RoutedEventArgs e) => Brain.WireAll();
    private void UnwireAll_Click(object sender, RoutedEventArgs e) => Brain.WireAll(enable: false);
    private void GrokSnippet_Click(object sender, RoutedEventArgs e) => Brain.CopyGrokSnippet();

    private void Provider_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ApiFields is null) return; // fires during InitializeComponent
        RefreshUi();
    }

    private void Fields_Changed(object sender, TextChangedEventArgs e)
    {
        if (UrlWarning is null || SaveSummarizer is null) return;
        RefreshUi();
    }

    private void SaveSummarizer_Click(object sender, RoutedEventArgs e)
    {
        var pairs = new List<(string, string)> { ("summarizer.provider", SelectedProvider) };
        if (UsesApi)
        {
            if (UrlBox.Text.Trim() is { Length: > 0 } url) pairs.Add(("summarizer.url", url));
            if (ModelBox.Text.Trim() is { Length: > 0 } model) pairs.Add(("summarizer.model", model));
            if (KeyEnvBox.Text.Trim() is { Length: > 0 } env) pairs.Add(("summarizer.apiKeyEnv", env));
            if (KeyBox.Password is { Length: > 0 } key) pairs.Add(("summarizer.apiKey", key));
        }
        Brain.SetConfig(pairs);
        KeyBox.Password = "";
    }

    private void Done_Click(object sender, RoutedEventArgs e) => Close();
}
