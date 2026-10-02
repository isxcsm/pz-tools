using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace PzTools.App;

/// <summary>
/// A key combination that reaches the app while another program, the game, has the keyboard. Windows gives it to
/// the app alone while it is registered, so it is registered only while something needs it. The first combination
/// no other program holds is taken.
/// </summary>
internal sealed class GlobalHotKey : IDisposable
{
    private const uint WmHotKey = 0x0312;
    private const uint ModAlt = 0x1, ModControl = 0x2, ModShift = 0x4, ModNoRepeat = 0x4000;
    private const nuint SubclassId = 0x505B;
    private const int HotKeyId = 0x5A01;

    // F9 and F10 with two modifiers: the game binds neither, and a held key does not repeat.
    private static readonly (uint Modifiers, uint Key, string Text)[] Candidates =
    [
        (ModControl | ModShift, 0x78, "Ctrl+Shift+F9"),
        (ModControl | ModShift, 0x79, "Ctrl+Shift+F10"),
        (ModControl | ModAlt, 0x78, "Ctrl+Alt+F9"),
        (ModControl | ModAlt, 0x79, "Ctrl+Alt+F10"),
    ];

    private readonly nint hwnd;
    private readonly SubclassProc callback;
    private readonly Action pressed;
    private bool disposed;

    private GlobalHotKey(nint hwnd, Action pressed, string text)
    {
        this.hwnd = hwnd;
        this.pressed = pressed;
        Text = text;
        callback = WindowProc;
    }

    /// <summary>How the combination is written, such as "Ctrl+Shift+F9".</summary>
    public string Text { get; }

    /// <summary>
    /// The first free combination, calling <paramref name="pressed"/> on the window's thread each time it is pressed;
    /// null when every one is taken or the window cannot receive it.
    /// </summary>
    public static GlobalHotKey? TryRegister(Window window, Action pressed)
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        foreach (var (modifiers, key, text) in Candidates)
        {
            if (!RegisterHotKey(hwnd, HotKeyId, modifiers | ModNoRepeat, key)) continue;
            var hotKey = new GlobalHotKey(hwnd, pressed, text);
            if (SetWindowSubclass(hwnd, hotKey.callback, SubclassId, 0)) return hotKey;
            UnregisterHotKey(hwnd, HotKeyId);
            return null;
        }
        return null;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        UnregisterHotKey(hwnd, HotKeyId);
        RemoveWindowSubclass(hwnd, callback, SubclassId);
    }

    private nint WindowProc(nint window, uint message, nint wParam, nint lParam, nuint id, nint reference)
    {
        if (message == WmHotKey && wParam == HotKeyId && !disposed)
        {
            pressed();
            return 0;
        }
        return DefSubclassProc(window, message, wParam, lParam);
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate nint SubclassProc(nint hwnd, uint message, nint wParam, nint lParam, nuint id, nint reference);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterHotKey(nint hwnd, int id);

    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(nint hwnd, SubclassProc callback, nuint id, nint reference);

    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveWindowSubclass(nint hwnd, SubclassProc callback, nuint id);

    [DllImport("comctl32.dll")]
    private static extern nint DefSubclassProc(nint hwnd, uint message, nint wParam, nint lParam);
}

/// <summary>The sounds Windows plays for its own messages: heard over a game that hides the app.</summary>
internal static class SystemSound
{
    public static void Accepted() => MessageBeep(0x0);
    public static void Done() => MessageBeep(0x40);
    public static void Failed() => MessageBeep(0x10);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool MessageBeep(uint type);
}
