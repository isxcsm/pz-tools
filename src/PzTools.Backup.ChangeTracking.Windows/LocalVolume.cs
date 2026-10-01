using System.Runtime.InteropServices;
using System.Text;

namespace PzTools.Backup.ChangeTracking.Windows;

public static class LocalVolume
{
    /// <summary>
    /// True when the path is on a local NTFS volume. There, a file's last-write and change times, read
    /// through a handle, move with every write, also while the writer keeps the file open. A network
    /// share can report "NTFS" for the server's disk, so remote drives are excluded explicitly.
    /// </summary>
    public static bool IsLocalNtfs(string path)
    {
        try
        {
            var root = new StringBuilder(261);
            if (!NativeMethods.GetVolumePathName(Path.GetFullPath(path), root, root.Capacity)) return false;
            if (NativeMethods.GetDriveType(root.ToString()) != DriveFixed) return false;
            var fileSystem = new StringBuilder(32);
            return NativeMethods.GetVolumeInformation(root.ToString(), null, 0, out _, out _, out _, fileSystem, fileSystem.Capacity)
                && string.Equals(fileSystem.ToString(), "NTFS", StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or NotSupportedException)
        {
            return false;
        }
    }

    private const uint DriveFixed = 3;

    private static class NativeMethods
    {
        [DllImport("kernel32.dll", EntryPoint = "GetVolumePathNameW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetVolumePathName(string fileName, StringBuilder volumePathName, int bufferLength);

        [DllImport("kernel32.dll", EntryPoint = "GetDriveTypeW", CharSet = CharSet.Unicode)]
        public static extern uint GetDriveType(string rootPathName);

        [DllImport("kernel32.dll", EntryPoint = "GetVolumeInformationW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetVolumeInformation(string rootPathName, StringBuilder? volumeNameBuffer, int volumeNameSize,
            out uint volumeSerialNumber, out uint maximumComponentLength, out uint fileSystemFlags,
            StringBuilder? fileSystemNameBuffer, int fileSystemNameSize);
    }
}
