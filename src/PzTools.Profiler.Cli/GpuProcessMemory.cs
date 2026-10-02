using System.Runtime.InteropServices;

/// <summary>
/// The video memory one process holds, as Windows counts it per process ("GPU Process Memory", the same
/// figures as Task Manager's GPU memory columns): on the graphics card, and system memory the card borrows.
/// Other programs' use is left out by matching the counter instances to the process id. Read from outside
/// the game, since the game cannot measure this itself.
/// </summary>
internal sealed class GpuProcessMemory : IDisposable
{
    private const uint FormatLarge = 0x00000400;
    private const uint MoreData = 0x800007D2;
    private readonly IntPtr query, dedicated, shared;
    private readonly string prefix;

    private GpuProcessMemory(IntPtr query, IntPtr dedicated, IntPtr shared, int processId)
    {
        (this.query, this.dedicated, this.shared) = (query, dedicated, shared);
        prefix = $"pid_{processId}_";
    }

    /// <summary>Null where the counters do not exist (before Windows 10 1709, or without a graphics driver that reports them).</summary>
    public static GpuProcessMemory? TryOpen(int processId)
    {
        if (PdhOpenQueryW(null, IntPtr.Zero, out var query) != 0) return null;
        // English names, which also work on a Windows installed in another language.
        if (PdhAddEnglishCounterW(query, @"\GPU Process Memory(*)\Dedicated Usage", IntPtr.Zero, out var dedicated) != 0
            || PdhAddEnglishCounterW(query, @"\GPU Process Memory(*)\Shared Usage", IntPtr.Zero, out var shared) != 0)
        {
            PdhCloseQuery(query);
            return null;
        }
        return new GpuProcessMemory(query, dedicated, shared, processId);
    }

    /// <summary>Bytes now, or null when Windows gave no reading this time.</summary>
    public (long Dedicated, long Shared)? Read()
    {
        if (PdhCollectQueryData(query) != 0) return null;
        var first = Sum(dedicated);
        var second = Sum(shared);
        return first is { } d && second is { } s ? (d, s) : null;
    }

    // One instance per graphics adapter and memory segment of each process; this process's are added up.
    private long? Sum(IntPtr counter)
    {
        uint size = 0;
        var status = PdhGetFormattedCounterArrayW(counter, FormatLarge, ref size, out _, IntPtr.Zero);
        if (status != MoreData || size == 0) return null;
        var buffer = Marshal.AllocHGlobal((int)size);
        try
        {
            if (PdhGetFormattedCounterArrayW(counter, FormatLarge, ref size, out var count, buffer) != 0) return null;
            // PDH_FMT_COUNTERVALUE_ITEM_W on x64: name pointer, status, padding, 64-bit value.
            const int itemSize = 24;
            long total = 0;
            var found = false;
            for (var index = 0; index < count; index++)
            {
                var item = buffer + index * itemSize;
                var name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(item));
                if (name is null || !name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;
                if (Marshal.ReadInt32(item, 8) != 0) continue;
                total += Marshal.ReadInt64(item, 16);
                found = true;
            }
            return found ? total : 0;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public void Dispose() => PdhCloseQuery(query);

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    private static extern uint PdhOpenQueryW(string? source, IntPtr userData, out IntPtr query);

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    private static extern uint PdhAddEnglishCounterW(IntPtr query, string path, IntPtr userData, out IntPtr counter);

    [DllImport("pdh.dll")]
    private static extern uint PdhCollectQueryData(IntPtr query);

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    private static extern uint PdhGetFormattedCounterArrayW(IntPtr counter, uint format, ref uint bufferSize, out uint itemCount, IntPtr buffer);

    [DllImport("pdh.dll")]
    private static extern uint PdhCloseQuery(IntPtr query);
}
