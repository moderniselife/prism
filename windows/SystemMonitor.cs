using System.Runtime.InteropServices;

namespace CursorProfiles;

/// <summary>
/// Honest machine telemetry. No hardcoded totals: physical RAM comes from the
/// runtime and CPU % from kernel times deltas (null until the second sample).
/// </summary>
public static class SystemMonitor
{
    public static long TotalPhysicalMemoryBytes { get; } = InitTotalMemory();

    private static long InitTotalMemory()
    {
        try { return (long)GC.GetGCMemoryInfo().TotalAvailableMemoryBytes; }
        catch { return 0; }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME
    {
        public uint Low;
        public uint High;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);

    private static ulong ToUlong(FILETIME t) => ((ulong)t.High << 32) | t.Low;

    private static readonly object _lock = new();
    private static ulong _prevIdle, _prevTotal;
    private static bool _hasPrev;

    public static double? SampleCpuPercent()
    {
        lock (_lock)
        {
            if (!GetSystemTimes(out var idle, out var kernel, out var user))
                return null;
            var idleU = ToUlong(idle);
            var total = ToUlong(kernel) + ToUlong(user);
            var prevIdle = _prevIdle;
            var prevTotal = _prevTotal;
            _prevIdle = idleU;
            _prevTotal = total;
            if (!_hasPrev)
            {
                _hasPrev = true;
                return null; // need two samples for a delta
            }
            var idleDelta = idleU - prevIdle;
            var totalDelta = total - prevTotal;
            if (totalDelta == 0) return null;
            var pct = (1.0 - (double)idleDelta / totalDelta) * 100.0;
            return Math.Clamp(pct, 0, 100);
        }
    }
}
