using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace CursorProfiles;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        // Turn silent startup deaths into evidence: every unhandled
        // exception lands in %TEMP%\Prism-crash.log (and a dialog when
        // there is a UI thread to show one on).
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            CrashLog.Report("AppDomain", args.ExceptionObject as Exception);
        DispatcherUnhandledException += (_, args) =>
        {
            CrashLog.Report("Dispatcher", args.Exception);
            try
            {
                MessageBox.Show(
                    $"Prism hit a problem and has to close.\n\n{args.Exception?.Message}\n\n" +
                    $"Full details in %TEMP%\\Prism-crash.log",
                    "Prism", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            catch { /* last resort: the log file already has it */ }
            args.Handled = true;
            Shutdown(1);
        };
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            CrashLog.Report("Task", args.Exception);
            args.SetObserved();
        };
        base.OnStartup(e);
    }
}

/// <summary>File-based crash reporter. Logging must never throw.</summary>
public static class CrashLog
{
    public static string LogPath { get; } =
        System.IO.Path.Combine(System.IO.Path.GetTempPath(), "Prism-crash.log");

    public static void Report(string source, Exception? ex)
    {
        try
        {
            System.IO.File.AppendAllText(LogPath,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] [{source}] {ex?.ToString() ?? "(no exception)"}{Environment.NewLine}");
        }
        catch { /* logging must never crash the crash reporter */ }
    }
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
