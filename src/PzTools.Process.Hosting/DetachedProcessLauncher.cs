using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace PzTools.Process.Hosting;

/// <summary>Detaches the given long-running work while keeping the supervised process tree.</summary>
public static class DetachedProcessLauncher
{
    private const uint CreateNoWindow = 0x08000000;
    private const uint CreateBreakawayFromJob = 0x01000000;
    private const int AccessDenied = 5;

    public static int Start(
        string executable, IReadOnlyList<string> arguments, string workingDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executable);
        ArgumentNullException.ThrowIfNull(arguments);
        ArgumentException.ThrowIfNullOrWhiteSpace(workingDirectory);
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("Detached maintenance processes require Windows.");

        var commandLine = new StringBuilder(Quote(Path.GetFullPath(executable)));
        foreach (var argument in arguments)
            commandLine.Append(' ').Append(Quote(argument));
        var startup = new StartupInfo { Size = (uint)Marshal.SizeOf<StartupInfo>() };
        if (!TryCreate(CreateNoWindow | CreateBreakawayFromJob, out var process, out var error))
        {
            // Whatever started this process may have put it in a job that forbids leaving it;
            // Windows then refuses the breakaway itself. Start the work inside that job instead.
            if (error != AccessDenied || !TryCreate(CreateNoWindow, out process, out error))
                throw new Win32Exception(error);
        }

        bool TryCreate(uint flags, out ProcessInformation created, out int lastError)
        {
            var succeeded = CreateProcess(
                Path.GetFullPath(executable), new StringBuilder(commandLine.ToString()),
                nint.Zero, nint.Zero, false, flags,
                nint.Zero, Path.GetFullPath(workingDirectory), ref startup, out created);
            lastError = succeeded ? 0 : Marshal.GetLastWin32Error();
            return succeeded;
        }

        try { return checked((int)process.ProcessId); }
        finally
        {
            CloseHandle(process.ThreadHandle);
            CloseHandle(process.ProcessHandle);
        }
    }

    private static string Quote(string value)
    {
        var result = new StringBuilder("\"");
        var slashes = 0;
        foreach (var character in value)
        {
            if (character == '\\') { slashes++; continue; }
            if (character == '"')
            {
                result.Append('\\', slashes * 2 + 1).Append('"');
                slashes = 0;
                continue;
            }
            result.Append('\\', slashes).Append(character);
            slashes = 0;
        }
        result.Append('\\', slashes * 2).Append('"');
        return result.ToString();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfo
    {
        public uint Size;
        public nint Reserved;
        public nint Desktop;
        public nint Title;
        public uint X;
        public uint Y;
        public uint XSize;
        public uint YSize;
        public uint XCountChars;
        public uint YCountChars;
        public uint FillAttribute;
        public uint Flags;
        public ushort ShowWindow;
        public ushort Reserved2;
        public nint Reserved2Pointer;
        public nint StandardInput;
        public nint StandardOutput;
        public nint StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public nint ProcessHandle;
        public nint ThreadHandle;
        public uint ProcessId;
        public uint ThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcess(
        string applicationName, StringBuilder commandLine,
        nint processAttributes, nint threadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
        uint creationFlags, nint environment, string currentDirectory,
        ref StartupInfo startupInfo, out ProcessInformation processInformation);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(nint handle);
}
