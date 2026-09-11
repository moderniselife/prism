using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace CursorProfiles;

public partial class App : Application
{
}

/// <summary>Turns on the dark (immersive) title bar for a window on Windows 10 20H1+.</summary>
public static class DarkTitleBar
{
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    public static void Apply(Window window)
    {
        window.SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(window).Handle;
            int on = 1;
            // 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (19 on older builds)
            _ = DwmSetWindowAttribute(hwnd, 20, ref on, sizeof(int));
            _ = DwmSetWindowAttribute(hwnd, 19, ref on, sizeof(int));
        };
    }
}
