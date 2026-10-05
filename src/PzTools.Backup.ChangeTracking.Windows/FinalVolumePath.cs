using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace PzTools.Backup.ChangeTracking.Windows;

/// <summary>
/// The volume a folder's files are really on. A save folder may be, or lie beneath, a junction or
/// symbolic link to another drive (the Zomboid folder moved to a larger disk). GetVolumePathName
/// reads the path as written and so names the drive of the link, whose change journal never sees
/// the save. Opening the folder follows every link, and the handle's final path names the volume
/// that holds it.
/// </summary>
public static class FinalVolumePath
{
    private const uint FileReadAttributes = 0x00000080;
    private const uint OpenExisting = 3;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint VolumeNameGuid = 0x1;

    /// <summary>The followed path in volume GUID form, <c>\\?\Volume{...}\folder</c>.</summary>
    public static string Resolve(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        using var handle = NativeMethods.CreateFile(
            Path.GetFullPath(path),
            FileReadAttributes,
            FileShare.ReadWrite | FileShare.Delete,
            IntPtr.Zero,
            OpenExisting,
            FileFlagBackupSemantics,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        var buffer = new StringBuilder(512);
        while (true)
        {
            var length = NativeMethods.GetFinalPathNameByHandle(handle, buffer, buffer.Capacity, VolumeNameGuid);
            if (length == 0)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            // Too small: the return value is the size needed, including the terminating null.
            if (length < buffer.Capacity)
            {
                return buffer.ToString();
            }

            buffer.Capacity = checked((int)length);
        }
    }

    /// <summary>The root of the volume the followed path is on, <c>\\?\Volume{...}\</c>.</summary>
    public static string ResolveVolumeRoot(string path)
    {
        var final = Resolve(path);
        const string prefix = @"\\?\Volume{";
        var end = final.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            ? final.IndexOf('\\', prefix.Length)
            : -1;
        return end < 0
            ? throw new InvalidDataException($"Unexpected volume path '{final}'.")
            : final[..(end + 1)];
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

        [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", CharSet = CharSet.Unicode,
            SetLastError = true)]
        public static extern uint GetFinalPathNameByHandle(
            SafeFileHandle file,
            StringBuilder filePath,
            int filePathLength,
            uint flags);
    }
}
