using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using PzTools.Backup.Core.Capture;

namespace PzTools.Backup.ChangeTracking.Windows;

public sealed class WindowsFileMetadataReader : IConcurrentFileMetadataReader
{
    public FileCaptureMetadata ReadPath(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        using var handle = NativeMethods.CreateFile(
            path,
            0x00000080,
            FileShare.ReadWrite | FileShare.Delete,
            IntPtr.Zero,
            3,
            0x02000000,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error);
        }

        return ReadHandle(handle);
    }

    public FileCaptureMetadata ReadHandle(SafeFileHandle handle)
    {
        ArgumentNullException.ThrowIfNull(handle);
        if (handle.IsInvalid || handle.IsClosed)
        {
            throw new ArgumentException("File handle is not open.", nameof(handle));
        }

        var identity = ReadIdentity(handle);
        if (!NativeMethods.GetFileInformationByHandleEx(
            handle,
            FileInfoByHandleClass.FileBasicInfo,
            out FileBasicInfo basic,
            (uint)Marshal.SizeOf<FileBasicInfo>()))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        if (!NativeMethods.GetFileInformationByHandleEx(
            handle,
            FileInfoByHandleClass.FileStandardInfo,
            out FileStandardInfo standard,
            (uint)Marshal.SizeOf<FileStandardInfo>()))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        return new FileCaptureMetadata(
            identity,
            standard.EndOfFile,
            FromFileTime(basic.LastWriteTime),
            FromFileTime(basic.ChangeTime),
            (FileAttributes)basic.FileAttributes,
            Usn: null);
    }

    // FAT32 refuses FileIdInfo with ERROR_INVALID_PARAMETER (measured on a USB stick). Its 64-bit file
    // index, from the older call, takes the same identity format. FAT keeps no change time: it reads as zero.
    private static string ReadIdentity(SafeFileHandle handle)
    {
        if (NativeMethods.GetFileInformationByHandleEx(
            handle,
            FileInfoByHandleClass.FileIdInfo,
            out FileIdInfo id,
            (uint)Marshal.SizeOf<FileIdInfo>()))
        {
            return FormattableString.Invariant(
                $"{id.VolumeSerialNumber:X16}:{id.FileId.HighPart:X16}{id.FileId.LowPart:X16}");
        }

        var error = Marshal.GetLastWin32Error();
        if (error is not (ErrorInvalidFunction or ErrorNotSupported or ErrorInvalidParameter))
        {
            throw new Win32Exception(error);
        }

        if (!NativeMethods.GetFileInformationByHandle(handle, out var legacy))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        return FormattableString.Invariant(
            $"{(ulong)legacy.VolumeSerialNumber:X16}:{0UL:X16}{legacy.FileIndexHigh:X8}{legacy.FileIndexLow:X8}");
    }

    private const int ErrorInvalidFunction = 1;
    private const int ErrorNotSupported = 50;
    private const int ErrorInvalidParameter = 87;

    private static DateTimeOffset FromFileTime(long value) =>
        new(DateTime.FromFileTimeUtc(value));

    private enum FileInfoByHandleClass
    {
        FileBasicInfo = 0,
        FileStandardInfo = 1,
        FileIdInfo = 18,
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileId128
    {
        public ulong LowPart;
        public ulong HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileIdInfo
    {
        public ulong VolumeSerialNumber;
        public FileId128 FileId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileBasicInfo
    {
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public long ChangeTime;
        public uint FileAttributes;
        public uint Reserved;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileStandardInfo
    {
        public long AllocationSize;
        public long EndOfFile;
        public uint NumberOfLinks;

        [MarshalAs(UnmanagedType.Bool)]
        public bool DeletePending;

        [MarshalAs(UnmanagedType.Bool)]
        public bool Directory;
    }

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
        public static extern bool GetFileInformationByHandleEx(
            SafeFileHandle fileHandle,
            FileInfoByHandleClass fileInformationClass,
            out FileIdInfo fileInformation,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetFileInformationByHandleEx(
            SafeFileHandle fileHandle,
            FileInfoByHandleClass fileInformationClass,
            out FileBasicInfo fileInformation,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetFileInformationByHandleEx(
            SafeFileHandle fileHandle,
            FileInfoByHandleClass fileInformationClass,
            out FileStandardInfo fileInformation,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetFileInformationByHandle(
            SafeFileHandle fileHandle,
            out ByHandleFileInformation fileInformation);
    }
}
