using System.Runtime.InteropServices;

namespace PzTools.Process.Hosting;

public sealed class ProcessTreeJob : IDisposable
{
    private nint handle;

    private ProcessTreeJob(nint handle) => this.handle = handle;

    public static ProcessTreeJob CreateKillOnClose()
    {
        var handle = CreateJobObject(nint.Zero, null);
        if (handle == nint.Zero) throw new System.ComponentModel.Win32Exception();
        var information = new JobObjectExtendedLimitInformation
        {
            BasicLimitInformation = new JobObjectBasicLimitInformation
            {
                LimitFlags = 0x00002000 | 0x00000800,
            },
        };
        var length = Marshal.SizeOf<JobObjectExtendedLimitInformation>();
        nint pointer = nint.Zero;
        try
        {
            pointer = Marshal.AllocHGlobal(length);
            Marshal.StructureToPtr(information, pointer, false);
            if (!SetInformationJobObject(handle, 9, pointer, (uint)length))
                throw new System.ComponentModel.Win32Exception();
            return new ProcessTreeJob(handle);
        }
        catch
        {
            CloseHandle(handle);
            throw;
        }
        finally
        {
            if (pointer != nint.Zero) Marshal.FreeHGlobal(pointer);
        }
    }

    public void Assign(System.Diagnostics.Process process)
    {
        ObjectDisposedException.ThrowIf(handle == nint.Zero, this);
        if (!AssignProcessToJobObject(handle, process.Handle))
            throw new System.ComponentModel.Win32Exception();
    }

    public void Terminate()
    {
        if (handle != nint.Zero) _ = TerminateJobObject(handle, 1);
    }

    public void Dispose()
    {
        var current = Interlocked.Exchange(ref handle, nint.Zero);
        if (current != nint.Zero) _ = CloseHandle(current);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public nuint MinimumWorkingSetSize;
        public nuint MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public nuint Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public nuint ProcessMemoryLimit;
        public nuint JobMemoryLimit;
        public nuint PeakProcessMemoryUsed;
        public nuint PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreateJobObject(nint securityAttributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(nint job, int infoClass, nint info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(nint job, nint process);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateJobObject(nint job, uint exitCode);
    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(nint handle);
}
