using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace PzTools.Backup.ChangeTracking.Windows;

public interface IUsnJournalSource
{
    UsnJournalState Query(string sourcePath);

    IEnumerable<UsnRecord> ReadRange(
        string sourcePath,
        UsnCheckpoint checkpoint,
        long upperUsnExclusive,
        CancellationToken cancellationToken = default);
}

public sealed class UsnJournalReader : IUsnJournalSource
{
    private const uint FsctlReadUsnJournal = 0x000900bb;
    private const uint FsctlQueryUsnJournal = 0x000900f4;
    private const uint GenericRead = 0x80000000;
    private const uint OpenExisting = 3;
    private const uint AllReasons = 0xffffffff;
    private const int BufferSize = 1024 * 1024;

    public UsnJournalState Query(string sourcePath)
    {
        var volume = ResolveVolume(sourcePath);
        using var handle = OpenVolume(volume.DevicePath);
        var buffer = new byte[80];
        if (!NativeMethods.DeviceIoControl(
            handle,
            FsctlQueryUsnJournal,
            IntPtr.Zero,
            0,
            buffer,
            buffer.Length,
            out var bytesReturned,
            IntPtr.Zero))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        if (bytesReturned < 56)
        {
            throw new InvalidDataException("USN journal query returned a truncated structure.");
        }

        return new UsnJournalState(
            volume.SerialNumber,
            BitConverter.ToUInt64(buffer, 0),
            BitConverter.ToInt64(buffer, 8),
            BitConverter.ToInt64(buffer, 16),
            BitConverter.ToInt64(buffer, 24));
    }

    public IEnumerable<UsnRecord> ReadRange(
        string sourcePath,
        UsnCheckpoint checkpoint,
        long upperUsnExclusive,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(checkpoint);
        if (upperUsnExclusive < checkpoint.NextUsn)
        {
            throw new ArgumentOutOfRangeException(
                nameof(upperUsnExclusive),
                "Upper USN cannot be behind the checkpoint.");
        }

        var currentState = Query(sourcePath);
        var decision = UsnCheckpointEvaluator.Evaluate(checkpoint, currentState);
        if (!decision.CanReadIncrementally)
        {
            throw new InvalidOperationException(decision.Reason);
        }

        if (upperUsnExclusive > currentState.NextUsn)
        {
            throw new ArgumentOutOfRangeException(
                nameof(upperUsnExclusive),
                "Upper USN is ahead of the queried journal state.");
        }

        return ReadRangeCore(
            ResolveVolume(sourcePath).DevicePath,
            checkpoint.NextUsn,
            upperUsnExclusive,
            checkpoint.JournalId,
            cancellationToken);
    }

    private static IEnumerable<UsnRecord> ReadRangeCore(
        string volumeDevicePath,
        long startUsn,
        long upperUsnExclusive,
        ulong journalId,
        CancellationToken cancellationToken)
    {
        using var handle = OpenVolume(volumeDevicePath);
        var currentUsn = startUsn;
        var output = new byte[BufferSize];
        while (currentUsn < upperUsnExclusive)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var request = new ReadUsnJournalDataV1
            {
                StartUsn = currentUsn,
                ReasonMask = AllReasons,
                ReturnOnlyOnClose = 0,
                Timeout = 0,
                BytesToWaitFor = 0,
                UsnJournalId = journalId,
                MinMajorVersion = 2,
                MaxMajorVersion = 3,
            };
            if (!NativeMethods.DeviceIoControl(
                handle,
                FsctlReadUsnJournal,
                ref request,
                Marshal.SizeOf<ReadUsnJournalDataV1>(),
                output,
                output.Length,
                out var bytesReturned,
                IntPtr.Zero))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            var parsed = UsnRecordParser.ParseJournalBuffer(output.AsSpan(0, bytesReturned));
            foreach (var record in parsed.Records)
            {
                if (record.Usn >= startUsn && record.Usn < upperUsnExclusive)
                {
                    yield return record;
                }
            }

            if (parsed.NextUsn <= currentUsn)
            {
                yield break;
            }

            currentUsn = parsed.NextUsn;
        }
    }

    private static ResolvedVolume ResolveVolume(string sourcePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePath);
        var absolutePath = Path.GetFullPath(sourcePath);
        var volumeRoot = new StringBuilder(261);
        if (!NativeMethods.GetVolumePathName(absolutePath, volumeRoot, volumeRoot.Capacity))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        var volumeName = new StringBuilder(51);
        if (!NativeMethods.GetVolumeNameForVolumeMountPoint(
            volumeRoot.ToString(),
            volumeName,
            volumeName.Capacity))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        if (!NativeMethods.GetVolumeInformation(
            volumeRoot.ToString(),
            null,
            0,
            out var serialNumber,
            out _,
            out _,
            null,
            0))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        return new ResolvedVolume(
            volumeName.ToString().TrimEnd(Path.DirectorySeparatorChar),
            serialNumber);
    }

    private static SafeFileHandle OpenVolume(string devicePath)
    {
        var handle = NativeMethods.CreateFile(
            devicePath,
            GenericRead,
            FileShare.ReadWrite | FileShare.Delete,
            IntPtr.Zero,
            OpenExisting,
            0,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error);
        }

        return handle;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ReadUsnJournalDataV1
    {
        public long StartUsn;
        public uint ReasonMask;
        public uint ReturnOnlyOnClose;
        public ulong Timeout;
        public ulong BytesToWaitFor;
        public ulong UsnJournalId;
        public ushort MinMajorVersion;
        public ushort MaxMajorVersion;
    }

    private sealed record ResolvedVolume(string DevicePath, ulong SerialNumber);

    private static class NativeMethods
    {
        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode,
            SetLastError = true)]
        public static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DeviceIoControl(
            SafeFileHandle device,
            uint controlCode,
            IntPtr input,
            int inputSize,
            [Out] byte[] output,
            int outputSize,
            out int bytesReturned,
            IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DeviceIoControl(
            SafeFileHandle device,
            uint controlCode,
            ref ReadUsnJournalDataV1 input,
            int inputSize,
            [Out] byte[] output,
            int outputSize,
            out int bytesReturned,
            IntPtr overlapped);

        [DllImport("kernel32.dll", EntryPoint = "GetVolumePathNameW", CharSet = CharSet.Unicode,
            SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetVolumePathName(
            string fileName,
            StringBuilder volumePathName,
            int bufferLength);

        [DllImport("kernel32.dll", EntryPoint = "GetVolumeNameForVolumeMountPointW",
            CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetVolumeNameForVolumeMountPoint(
            string volumeMountPoint,
            StringBuilder volumeName,
            int bufferLength);

        [DllImport("kernel32.dll", EntryPoint = "GetVolumeInformationW",
            CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetVolumeInformation(
            string rootPathName,
            StringBuilder? volumeNameBuffer,
            int volumeNameSize,
            out uint volumeSerialNumber,
            out uint maximumComponentLength,
            out uint fileSystemFlags,
            StringBuilder? fileSystemNameBuffer,
            int fileSystemNameSize);
    }
}
