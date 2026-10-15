using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Win32;

namespace CursorProfiles;

/// <summary>
/// Light/dark theming. Brushes live in Themes/Dark.xaml + Themes/Light.xaml
/// (identical keys); every style and window references them with
/// DynamicResource so switching is live. "system" follows the Windows app
/// theme via the registry (re-resolved on the store's poll tick — no new
/// dependencies, ~4s latency).
/// </summary>
public static class ThemeManager
{
    public const string System = "system";
    public const string Light = "light";
    public const string Dark = "dark";

    /// <summary>Currently applied theme (true = dark). Defaults to dark.</summary>
    public static bool IsDark { get; private set; } = true;

    private static string _choice = System;
    private static bool _appliedOnce;

    public static string NormalizeChoice(string? choice) => choice switch
    {
        Light => Light,
        Dark => Dark,
        _ => System,
    };

    /// <summary>Resolves the OS app theme. True = Windows is in dark mode.</summary>
    public static bool SystemWantsDark()
    {
        try
        {
            var value = Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme", 1);
            return Convert.ToInt32(value) == 0;
        }
        catch
        {
            return false;
        }
    }

    public static bool ResolveIsDark(string? choice) => NormalizeChoice(choice) switch
    {
        Light => false,
        Dark => true,
        _ => SystemWantsDark(),
    };

    /// <summary>
    /// Applies a theme choice ("system"/"light"/"dark"). Safe headless
    /// (no Application) — records state and returns, so tests can call it.
    /// </summary>
    public static void ApplyTheme(string? choice)
    {
        _choice = NormalizeChoice(choice);
        bool isDark = ResolveIsDark(_choice);
        if (_appliedOnce && isDark == IsDark)
            return; // steady state: skip the dictionary rebuild
        IsDark = isDark;
        _appliedOnce = true;

        var app = Application.Current;
        if (app is null) return;

        var dicts = app.Resources.MergedDictionaries;
        for (int i = dicts.Count - 1; i >= 0; i--)
        {
            var src = dicts[i].Source?.OriginalString ?? "";
            if (src.Contains("Themes/Dark.xaml") || src.Contains("Themes/Light.xaml"))
                dicts.RemoveAt(i);
        }
        var asm = Assembly.GetExecutingAssembly().GetName().Name;
        dicts.Add((ResourceDictionary)Application.LoadComponent(
            new Uri($"/{asm};component/Themes/{(isDark ? "Dark" : "Light")}.xaml", UriKind.Relative)));

        // Re-tint open windows' title bars immediately.
        foreach (Window window in app.Windows)
            ApplyChrome(window);
    }

    /// <summary>
    /// Re-resolves "system" choices (cheap registry read). Called on the
    /// store's poll tick so OS theme flips apply within seconds.
    /// </summary>
    public static void RefreshIfSystem()
    {
        if (_choice == System)
            ApplyTheme(System);
    }

    /// <summary>Tints one window's title bar for the current theme.</summary>
    public static void ApplyChrome(Window window)
    {
        if (window.IsLoaded)
            ApplyChromeNow(window);
        else
            window.SourceInitialized += (_, _) => ApplyChromeNow(window);
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    private static void ApplyChromeNow(Window window)
    {
        try
        {
            var hwnd = new WindowInteropHelper(window).Handle;
            if (hwnd == IntPtr.Zero) return;
            int dark = IsDark ? 1 : 0;
            // 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (19 on older builds)
            _ = DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));
            _ = DwmSetWindowAttribute(hwnd, 19, ref dark, sizeof(int));
        }
        catch { /* chrome must never crash the app */ }
    }
}
