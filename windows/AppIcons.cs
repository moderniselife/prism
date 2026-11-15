using System.Windows.Media;

namespace CursorProfiles;

/// <summary>
/// Small line icons drawn on a 20×20 grid (stroke them, don't fill). Generic
/// shapes, not app logos: a pointer for Cursor, a terminal for Claude Code,
/// a window for Claude Desktop and a little bot for Grok Bot.
/// </summary>
public static class AppIcons
{
    private static Geometry Make(string data)
    {
        var g = Geometry.Parse(data);
        g.Freeze();
        return g;
    }

    public static readonly Geometry Cursor = Make("M5,3.5 L15.5,8.5 L11,10 L9.5,14.5 Z");
    public static readonly Geometry Terminal = Make(
        "M4.5,4 H15.5 A2,2 0 0 1 17.5,6 V14 A2,2 0 0 1 15.5,16 H4.5 A2,2 0 0 1 2.5,14 V6 A2,2 0 0 1 4.5,4 Z " +
        "M6,8.5 L8.5,10.5 L6,12.5 M10.5,12.5 H14");
    public static readonly Geometry Window = Make(
        "M4.5,3.5 H15.5 A2,2 0 0 1 17.5,5.5 V12 A2,2 0 0 1 15.5,14 H4.5 A2,2 0 0 1 2.5,12 V5.5 A2,2 0 0 1 4.5,3.5 Z " +
        "M7,17 H13 M10,14 V17");
    public static readonly Geometry Bot = Make(
        "M6.5,6.5 H13.5 A3,3 0 0 1 16.5,9.5 V13 A3,3 0 0 1 13.5,16 H6.5 A3,3 0 0 1 3.5,13 V9.5 A3,3 0 0 1 6.5,6.5 Z " +
        "M10,3.5 V6.5 M7.5,10.7 V11.3 M12.5,10.7 V11.3");

    // Sidebar filters
    public static readonly Geometry Stack = Make("M10,3 L17,7 L10,11 L3,7 Z M3,11 L10,15 L17,11");
    public static readonly Geometry Pulse = Make("M2.5,10 H5.5 L7.5,5 L11.5,15 L13.5,10 H17.5");
    public static readonly Geometry Person = Make(
        "M10,4 A3,3 0 1 1 9.99,4 Z M4,16.5 C5,13.5 7.5,12 10,12 C12.5,12 15,13.5 16,16.5");
    public static readonly Geometry Brain = Make(
        "M8,3.5 A2.5,2.5 0 0 0 5.5,6 V6.3 A2.6,2.6 0 0 0 4,10.7 A2.6,2.6 0 0 0 6,14.9 A2.5,2.5 0 0 0 10,16 V5.5 A2,2 0 0 0 8,3.5 Z " +
        "M12,3.5 A2.5,2.5 0 0 1 14.5,6 V6.3 A2.6,2.6 0 0 1 16,10.7 A2.6,2.6 0 0 1 14,14.9 A2.5,2.5 0 0 1 10,16");
    public static readonly Geometry Gear = Make(
        "M10,7 A3,3 0 1 1 9.99,7 Z M10,2.5 V4.5 M10,15.5 V17.5 M2.5,10 H4.5 M15.5,10 H17.5 " +
        "M4.7,4.7 L6.1,6.1 M13.9,13.9 L15.3,15.3 M4.7,15.3 L6.1,13.9 M13.9,6.1 L15.3,4.7");
    public static readonly Geometry Search = Make("M9,3.5 A5.5,5.5 0 1 1 8.99,3.5 Z M13,13 L16.5,16.5");
    public static readonly Geometry Plus = Make("M10,4.5 V15.5 M4.5,10 H15.5");
    public static readonly Geometry Arrow = Make("M4,10 H15 M11,6 L15,10 L11,14");
    public static readonly Geometry Folder = Make(
        "M3,6.5 A1.5,1.5 0 0 1 4.5,5 H8 L9.5,6.5 H15.5 A1.5,1.5 0 0 1 17,8 V14.5 A1.5,1.5 0 0 1 15.5,16 H4.5 A1.5,1.5 0 0 1 3,14.5 Z");
    public static readonly Geometry Pin = Make("M10,13 V17.5 M6,13 H14 L12.5,9 V4.5 H7.5 V9 Z");
    public static readonly Geometry Update = Make("M10,3 A7,7 0 1 1 9.99,3 Z M10,13.5 V6.5 M7,9 L10,6 L13,9");

    public static Geometry For(string app) => CursorProfile.NormalizeApp(app) switch
    {
        CursorProfile.AppClaudeCode => Terminal,
        CursorProfile.AppClaudeDesktop => Window,
        CursorProfile.AppGrokBot => Bot,
        _ => Cursor,
    };
}
