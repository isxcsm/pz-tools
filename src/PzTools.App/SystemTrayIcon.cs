using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace PzTools.App;

/// <summary>WinUI 창 HWND에 연결되는 Windows 알림 영역 아이콘입니다.</summary>
internal sealed class SystemTrayIcon : IDisposable
{
    private const uint CallbackMessage = 0x8000 + 42; // WM_APP + 42
    private const uint WmLeftDoubleClick = 0x0203;
    private const uint WmRightButtonUp = 0x0205;
    private const uint WmContextMenu = 0x007B;
    private const uint WmNull = 0;
    private const uint NimAdd = 0;
    private const uint NimModify = 1;
    private const uint NimDelete = 2;
    private const uint NifMessage = 1;
    private const uint NifIcon = 2;
    private const uint NifTip = 4;
    private const uint MfString = 0;
    private const uint MfSeparator = 0x0800;
    private const uint TpmRightButton = 0x0002;
    private const uint TpmReturnCommand = 0x0100;
    private const uint RestoreCommand = 1;
    private const uint ExitCommand = 2;
    private const nuint SubclassId = 0x505A;

    private readonly nint hwnd;
    private readonly nint icon;
    private readonly SubclassProc callback;
    private readonly Action restore;
    private readonly Action exit;
    private readonly uint taskbarCreated;
    private bool registered;
    private bool disposed;

    public SystemTrayIcon(Window window, string iconPath, Action restore, Action exit)
    {
        hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        this.restore = restore;
        this.exit = exit;
        icon = LoadImageW(0, iconPath, 1, 0, 0, 0x0010 | 0x0040);
        if (icon == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot load the system tray icon.");
        callback = WindowProc;
        if (!SetWindowSubclass(hwnd, callback, SubclassId, 0))
        {
            DestroyIcon(icon);
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot register the system tray window.");
        }
        taskbarCreated = RegisterWindowMessageW("TaskbarCreated");
        if (!AddIcon())
        {
            RemoveWindowSubclass(hwnd, callback, SubclassId);
            DestroyIcon(icon);
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot add the system tray icon.");
        }
    }

    public bool IsAvailable => registered && !disposed;

    public void RefreshTooltip()
    {
        if (!IsAvailable) return;
        var data = CreateData(NifTip);
        if (!Shell_NotifyIconW(NimModify, ref data)) registered = false;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        if (registered)
        {
            var data = CreateData(0);
            Shell_NotifyIconW(NimDelete, ref data);
            registered = false;
        }
        RemoveWindowSubclass(hwnd, callback, SubclassId);
        DestroyIcon(icon);
    }

    private bool AddIcon()
    {
        var data = CreateData(NifMessage | NifIcon | NifTip);
        registered = Shell_NotifyIconW(NimAdd, ref data);
        return registered;
    }

    private NotifyIconData CreateData(uint flags) => new()
    {
        Size = (uint)Marshal.SizeOf<NotifyIconData>(),
        Window = hwnd,
        Id = 1,
        Flags = flags,
        CallbackMessage = CallbackMessage,
        Icon = icon,
        ToolTip = Localizer.Get("AppTitle"),
        Info = string.Empty,
        InfoTitle = string.Empty,
    };

    private nint WindowProc(nint window, uint message, nint wParam, nint lParam,
        nuint id, nint reference)
    {
        if (taskbarCreated != 0 && message == taskbarCreated && !disposed)
        {
            registered = false;
            AddIcon();
        }
        else if (message == CallbackMessage)
        {
            switch ((uint)lParam.ToInt64())
            {
                case WmLeftDoubleClick:
                    restore();
                    return 0;
                case WmRightButtonUp:
                case WmContextMenu:
                    ShowMenu();
                    return 0;
            }
        }
        return DefSubclassProc(window, message, wParam, lParam);
    }

    private void ShowMenu()
    {
        if (!GetCursorPos(out var point)) return;
        var menu = CreatePopupMenu();
        if (menu == 0) return;
        try
        {
            AppendMenuW(menu, MfString, RestoreCommand, Localizer.Get("TrayRestore"));
            AppendMenuW(menu, MfSeparator, 0, null);
            AppendMenuW(menu, MfString, ExitCommand, Localizer.Get("TrayExit"));
            SetForegroundWindow(hwnd);
            var command = TrackPopupMenu(menu, TpmRightButton | TpmReturnCommand,
                point.X, point.Y, 0, hwnd, 0);
            PostMessageW(hwnd, WmNull, 0, 0);
            if (command == RestoreCommand) restore();
            else if (command == ExitCommand) exit();
        }
        finally { DestroyMenu(menu); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public nint Window;
        public uint Id;
        public uint Flags;
        public uint CallbackMessage;
        public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string ToolTip;
        public uint State;
        public uint StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint TimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags;
        public Guid GuidItem;
        public nint BalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X; public int Y; }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate nint SubclassProc(nint hwnd, uint message, nint wParam,
        nint lParam, nuint id, nint reference);

    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Shell_NotifyIconW(uint message, ref NotifyIconData data);

    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(nint hwnd, SubclassProc callback,
        nuint id, nint reference);

    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveWindowSubclass(nint hwnd, SubclassProc callback, nuint id);

    [DllImport("comctl32.dll")]
    private static extern nint DefSubclassProc(nint hwnd, uint message, nint wParam, nint lParam);

    [DllImport("user32.dll", EntryPoint = "LoadImageW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint LoadImageW(nint instance, string name, uint type,
        int width, int height, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(nint icon);

    [DllImport("user32.dll", EntryPoint = "RegisterWindowMessageW", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessageW(string name);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint CreatePopupMenu();

    [DllImport("user32.dll", EntryPoint = "AppendMenuW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AppendMenuW(nint menu, uint flags, nuint id, string? text);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyMenu(nint menu);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint TrackPopupMenu(nint menu, uint flags, int x, int y,
        int reserved, nint owner, nint rectangle);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint hwnd);

    [DllImport("user32.dll", EntryPoint = "PostMessageW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessageW(nint hwnd, uint message, nint wParam, nint lParam);
}
