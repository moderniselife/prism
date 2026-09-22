# Prism — Windows (WPF, .NET 8)

Native dark-themed Windows app, feature-identical to the macOS and Linux versions.
Profiles live in `%USERPROFILE%\.cursor_profiles`, metadata in `.profiles.json`
(same format on all three platforms). Your original Cursor profile (`%APPDATA%\Cursor`)
appears as a protected **Main Cursor** card — launchable and clonable, never deletable.
Deleting a managed profile sends it to the Recycle Bin, never `rmdir /s`.

**Pin the right instance to the taskbar:** the Pin button on a card (or "Create Taskbar
Shortcut…" in its menu) generates a Start Menu shortcut with its own icon — your
profile's color + initial, rendered as a real multi-resolution `.ico`. Find it in
Start → Prism, then right-click → **Pin to taskbar**. The shortcut always
opens that exact `--user-data-dir`, so Work and Personal stay visually distinct even
when both are pinned. Renaming or recoloring a profile updates its shortcut automatically.

**Note:** that custom icon only shows on the *pinned, idle* shortcut — once Cursor
actually launches, the taskbar shows Cursor's own icon for the running window,
because Cursor's build crashes if its executable is re-signed under a different
identity (confirmed by testing; this is deliberate anti-tamper protection, the same
technique Epichrome uses for Chrome profiles doesn't work here). To tell profiles
apart *while running*, each profile gets its own title bar color instead (see below).

One thing this version does *not* have: the macOS build originally generated a
per-profile wrapper `.app`, which turned out to multiply permission prompts (each
wrapper is a distinct signed app identity, and macOS ties Microphone/Camera/folder
consent to whichever bundle launched Cursor) — that feature was removed there. A
`.lnk` shortcut isn't a distinct app identity the same way; it's just a pointer to
the same `Cursor.exe`, so there's no equivalent identity for a permission system to
key off, and nothing extra to worry about here.

## Telling running profiles apart (title bar color)

Since the taskbar icon can't be rebranded once Cursor is open, every profile
automatically gets a distinct title bar color — `workbench.colorCustomizations` +
`"window.titleBarStyle": "custom"`, merged into that profile's `User/settings.json`
(`TitleBarColorizer.cs`). This makes Work/Personal/whatever instantly distinguishable
in the window itself and in Alt+Tab, even though the taskbar icon looks like stock
Cursor while running. Any of your own existing settings in that file are preserved —
only the title bar keys are merged in.

## Build & run

Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).

```powershell
dotnet run
```

Or publish the shippable exe — self-contained single-file, runtime and
dependencies bundled, no .NET install needed on the target machine:

```powershell
dotnet publish -c Release -r win-x64 --self-contained -o publish/win-x64 /p:PublishSingleFile=true
```

The exe lands at `publish\win-x64\Prism.exe`. That one file is the whole
app — don't split it up; running the exe without its published folder
mates is the classic "double-click and nothing happens".

## If it won't start

Silent exits leave evidence — check in this order:

1. **Run the published exe**, not a lone file copied out of `bin\Release`.
   The framework-dependent build needs its sibling `.dll` +
   `.runtimeconfig.json` next to it; the single-file publish above has no
   such requirement.
2. **Read the crash log** at `%TEMP%\Prism-crash.log` — every unhandled
   exception is written there, plus an error dialog when possible.
3. **Run from a terminal** (`cmd`, not double-click) so host errors print:
   ```powershell
   publish\win-x64\Prism.exe
   ```
   With the SDK installed you get full managed output via the DLL instead:
   ```powershell
   dotnet bin\Debug\net8.0-windows\Prism.dll
   ```
4. **Event Viewer** → Windows Logs → Application → `.NET Runtime` entries
   at the launch timestamp.

## Cursor detection

Checks `%LOCALAPPDATA%\Programs\cursor\Cursor.exe`, `%PROGRAMFILES%\Cursor\Cursor.exe`
and `PATH`. A custom path can be set in Settings.

## Notes

- Running-profile detection uses WMI (`Win32_Process` command lines) to find the
  main Cursor process per `--user-data-dir`.
- The project cross-compiles from macOS/Linux too (`EnableWindowsTargeting`),
  which is how it's CI-verified from this repo. Icon generation (`ShortcutBuilder.cs`)
  uses `System.Drawing` + `IShellLinkW` COM interop, both Windows-only at runtime —
  those paths are exercised for real only when running on Windows.
