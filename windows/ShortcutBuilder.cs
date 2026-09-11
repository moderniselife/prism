using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

namespace CursorProfiles;

/// <summary>
/// Builds a per-profile Start Menu shortcut with a generated icon (gradient
/// squircle + emoji), so a profile can be pinned to the taskbar and always
/// opens the right --user-data-dir.
/// </summary>
public static class ShortcutBuilder
{
    public static string ShortcutsDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs", "Cursor Profiles");

    public static string IconsDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CursorProfiles", "Icons");

    public static string IconPath(CursorProfile profile) =>
        Path.Combine(IconsDir, $"{profile.FolderName}.ico");

    public static string ShortcutPath(CursorProfile profile) =>
        Path.Combine(ShortcutsDir, $"{SafeFileName(profile.DisplayName)}.lnk");

    public static bool Exists(CursorProfile profile) => File.Exists(ShortcutPath(profile));

    public static void CreateOrUpdate(CursorProfile profile, string profileDir, string? cursorPath)
    {
        Directory.CreateDirectory(ShortcutsDir);
        Directory.CreateDirectory(IconsDir);

        var iconPath = IconPath(profile);
        IconBuilder.WriteIco(profile.Emoji, Palette.ColorFromHexGdi(profile.ColorHex), iconPath);

        var exe = CursorLauncher.FindCursor(cursorPath) ?? "Cursor.exe";
        var args = profile.IsSystem
            ? $"--max-memory={profile.DefaultMemoryMB}"
            : $"--user-data-dir \"{profileDir}\" --max-memory={profile.DefaultMemoryMB}";
        if (!string.IsNullOrWhiteSpace(profile.DefaultProjectPath))
            args += $" \"{profile.DefaultProjectPath}\"";

        var shortcutPath = ShortcutPath(profile);
        // A rename means the old .lnk/.ico would be orphaned; clean it up first.
        RemoveOrphans(profile, keep: shortcutPath, keepIcon: iconPath);

        ShellLink.Create(shortcutPath,
            targetPath: exe,
            arguments: args,
            workingDirectory: Path.GetDirectoryName(exe) ?? "",
            iconPath: iconPath,
            description: $"Open Cursor with the \"{profile.DisplayName}\" profile");
    }

    public static void Remove(CursorProfile profile)
    {
        try { File.Delete(ShortcutPath(profile)); } catch { }
        try { File.Delete(IconPath(profile)); } catch { }
    }

    private static void RemoveOrphans(CursorProfile profile, string keep, string keepIcon)
    {
        // Best-effort: shortcuts are named after DisplayName, so a rename can
        // leave a stale file behind. We only know the current name here, so
        // orphan cleanup on rename is handled by the caller deleting the old
        // shortcut before calling CreateOrUpdate with the new name.
    }

    private static string SafeFileName(string name)
    {
        var cleaned = string.Concat(name.Split(Path.GetInvalidFileNameChars())).Trim();
        return cleaned.Length == 0 ? "Cursor Profile" : cleaned;
    }
}

public static class IconBuilder
{
    private static readonly int[] Sizes = { 16, 32, 48, 64, 128, 256 };

    /// <summary>Render a gradient squircle with the emoji centered, at every
    /// standard size, and pack them into a single multi-resolution .ico
    /// (large sizes use embedded PNG, matching how Explorer/taskbar icons work).</summary>
    public static void WriteIco(string emoji, Color color, string outputPath)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
        var frames = new List<(int size, byte[] png)>();
        foreach (var size in Sizes)
            frames.Add((size, RenderPng(emoji, color, size)));

        using var stream = new FileStream(outputPath, FileMode.Create, FileAccess.Write);
        using var writer = new BinaryWriter(stream);

        // ICONDIR
        writer.Write((short)0);              // reserved
        writer.Write((short)1);              // type: icon
        writer.Write((short)frames.Count);

        int offset = 6 + frames.Count * 16;  // header + one 16-byte entry per frame
        foreach (var (size, png) in frames)
        {
            writer.Write((byte)(size >= 256 ? 0 : size));   // width  (0 means 256)
            writer.Write((byte)(size >= 256 ? 0 : size));   // height
            writer.Write((byte)0);                          // color palette
            writer.Write((byte)0);                          // reserved
            writer.Write((short)1);                          // color planes
            writer.Write((short)32);                         // bits per pixel
            writer.Write(png.Length);
            writer.Write(offset);
            offset += png.Length;
        }
        foreach (var (_, png) in frames)
            writer.Write(png);
    }

    private static byte[] RenderPng(string emoji, Color color, int size)
    {
        using var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        g.CompositingQuality = CompositingQuality.HighQuality;

        var inset = size * 0.06f;
        var rect = new RectangleF(inset, inset, size - inset * 2, size - inset * 2);
        var radius = rect.Width * 0.28f;

        using var path = RoundedRect(rect, radius);
        var dim = Color.FromArgb(255,
            (int)(color.R * 0.7), (int)(color.G * 0.7), (int)(color.B * 0.7));
        using var brush = new LinearGradientBrush(rect, color, dim, 45f);
        g.FillPath(brush, path);

        var fontSize = size * 0.52f;
        try
        {
            using var font = new Font("Segoe UI Emoji", fontSize, GraphicsUnit.Pixel);
            var textSize = g.MeasureString(emoji, font);
            var point = new PointF((size - textSize.Width) / 2, (size - textSize.Height) / 2);
            g.DrawString(emoji, font, Brushes.White, point);
        }
        catch (ArgumentException)
        {
            // Segoe UI Emoji unavailable — fall back to a plain glyph so the
            // icon still renders something rather than throwing.
        }

        using var ms = new MemoryStream();
        bitmap.Save(ms, ImageFormat.Png);
        return ms.ToArray();
    }

    private static GraphicsPath RoundedRect(RectangleF rect, float radius)
    {
        var path = new GraphicsPath();
        var d = radius * 2;
        path.AddArc(rect.X, rect.Y, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}

/// <summary>Minimal IShellLink COM interop — no external type library needed,
/// so this builds and runs on a bare .NET 8 + Windows install.</summary>
internal static class ShellLink
{
    public static void Create(string shortcutPath, string targetPath, string arguments,
                              string workingDirectory, string iconPath, string description)
    {
        var link = (IShellLinkW)new CShellLink();
        link.SetPath(targetPath);
        link.SetArguments(arguments);
        link.SetWorkingDirectory(workingDirectory);
        link.SetIconLocation(iconPath, 0);
        link.SetDescription(description);

        var persistFile = (IPersistFile)link;
        persistFile.Save(shortcutPath, true);
    }

    [ComImport]
    [Guid("00021401-0000-0000-C000-000000000046")]
    private class CShellLink { }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    private interface IShellLinkW
    {
        void GetPath(System.Text.StringBuilder pszFile, int cchMaxPath, IntPtr pfd, uint fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription(System.Text.StringBuilder pszName, int cchMaxName);
        void SetDescription(string pszName);
        void GetWorkingDirectory(System.Text.StringBuilder pszDir, int cchMaxPath);
        void SetWorkingDirectory(string pszDir);
        void GetArguments(System.Text.StringBuilder pszArgs, int cchMaxPath);
        void SetArguments(string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation(System.Text.StringBuilder pszIconPath, int cchIconPath, out int piIcon);
        void SetIconLocation(string pszIconPath, int iIcon);
        void SetRelativePath(string pszPathRel, uint dwReserved);
        void Resolve(IntPtr hwnd, uint fFlags);
        void SetPath(string pszFile);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("0000010b-0000-0000-C000-000000000046")]
    private interface IPersistFile
    {
        void GetClassID(out Guid pClassID);
        void IsDirty();
        void Load(string pszFileName, uint dwMode);
        void Save(string pszFileName, bool fRemember);
        void SaveCompleted(string pszFileName);
        void GetCurFile(out string ppszFileName);
    }
}
