using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using PzTools.Process.Contracts;

namespace PzTools.App;

/// <summary>
/// Key combinations that reach the app while another program, the game, has the keyboard. Windows gives each to the
/// app alone while it is registered, so only the ones that have something to do are.
/// </summary>
internal sealed class GlobalHotKeys : IDisposable
{
    private const uint WmHotKey = 0x0312;
    private const uint ModNoRepeat = 0x4000;
    private const nuint SubclassId = 0x505B;
    private const int FirstId = 0x5A01;

    private readonly nint hwnd;
    private readonly SubclassProc callback;
    private readonly Action<HotKeyAction> pressed;
    private readonly Dictionary<int, HotKeyAction> byId = [];
    private readonly Dictionary<HotKeyAction, HotKeyGesture> registered = [];
    private bool subclassed, disposed;

    /// <param name="pressed">Called on the window's thread with the action whose combination was pressed.</param>
    public GlobalHotKeys(Window window, Action<HotKeyAction> pressed)
    {
        hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        this.pressed = pressed;
        callback = WindowProc;
    }

    /// <summary>The combinations in force now.</summary>
    public IReadOnlyDictionary<HotKeyAction, HotKeyGesture> Registered => registered;

    /// <summary>
    /// Registers exactly <paramref name="wanted"/>, releasing the rest; returns the actions whose combination another
    /// program holds.
    /// </summary>
    public IReadOnlyList<HotKeyAction> Apply(IReadOnlyDictionary<HotKeyAction, HotKeyGesture> wanted)
    {
        if (disposed) return [];
        if (!subclassed) subclassed = SetWindowSubclass(hwnd, callback, SubclassId, 0);
        var refused = new List<HotKeyAction>();
        // Everything that changes is released first: a combination moved from one action to another is then free
        // when the second takes it, whichever comes first.
        foreach (var (action, current) in registered.ToArray())
        {
            if (wanted.TryGetValue(action, out var keep) && keep == current) continue;
            var id = FirstId + (int)action;
            UnregisterHotKey(hwnd, id);
            registered.Remove(action);
            byId.Remove(id);
        }
        foreach (var action in Enum.GetValues<HotKeyAction>())
        {
            var id = FirstId + (int)action;
            if (registered.ContainsKey(action)) continue;
            if (!wanted.TryGetValue(action, out var next) || !subclassed) continue;
            if (RegisterHotKey(hwnd, id, Modifiers(next.Modifiers) | ModNoRepeat, (uint)next.Key))
            {
                registered[action] = next;
                byId[id] = action;
            }
            else refused.Add(action);
        }
        return refused;
    }

    /// <summary>Whether another program holds a combination now: tried and released at once.</summary>
    public bool IsFree(HotKeyGesture gesture)
    {
        if (registered.ContainsValue(gesture)) return true;
        const int probe = FirstId + 100;
        if (!RegisterHotKey(hwnd, probe, Modifiers(gesture.Modifiers) | ModNoRepeat, (uint)gesture.Key)) return false;
        UnregisterHotKey(hwnd, probe);
        return true;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        foreach (var id in byId.Keys) UnregisterHotKey(hwnd, id);
        byId.Clear();
        registered.Clear();
        if (subclassed) RemoveWindowSubclass(hwnd, callback, SubclassId);
    }

    // Windows' own flags: Alt 1, Control 2, Shift 4, Win 8, the same as the app's.
    private static uint Modifiers(HotKeyModifiers modifiers) => (uint)modifiers;

    private nint WindowProc(nint window, uint message, nint wParam, nint lParam, nuint id, nint reference)
    {
        if (message == WmHotKey && !disposed && byId.TryGetValue((int)wParam, out var action))
        {
            pressed(action);
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
