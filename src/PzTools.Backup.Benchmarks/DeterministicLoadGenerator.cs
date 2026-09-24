using System.Globalization;
using PzTools.Backup.ChangeTracking.Windows;

namespace PzTools.Backup.Benchmarks;

internal sealed class DeterministicLoadGenerator(int seed)
{
    private readonly Random random = new(seed);

    public async Task GenerateAsync(
        string root,
        int fileCount,
        int bytesPerFile,
        bool compressible,
        CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(root);
        Directory.CreateDirectory(Path.Combine(root, "empty"));
        Directory.CreateDirectory(Path.Combine(root, "유니코드"));
        var buffer = new byte[bytesPerFile];
        for (var index = 0; index < fileCount; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var directory = Path.Combine(root, $"d{index % 64:D2}", $"s{index % 7:D2}");
            Directory.CreateDirectory(directory);
            if (compressible)
            {
                Array.Fill(buffer, (byte)(index % 17));
            }
            else
            {
                random.NextBytes(buffer);
            }
            await File.WriteAllBytesAsync(
                Path.Combine(directory, $"file-{index:D7}.bin"),
                buffer,
                cancellationToken);
        }
    }

    public async Task<IReadOnlyList<UsnRecord>> MutateAsync(
        string root,
        int operationCount,
        long firstUsn,
        CancellationToken cancellationToken = default)
    {
        var metadata = new WindowsFileMetadataReader();
        var files = Directory.GetFiles(root, "*.bin", SearchOption.AllDirectories)
            .Order(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var count = Math.Min(operationCount, files.Length / 6);
        var records = new List<UsnRecord>(count * 8);
        long usn = firstUsn;

        for (var index = 0; index < count; index++)
        {
            var path = files[index];
            await File.WriteAllTextAsync(path, $"overwrite-{seed}-{index}", cancellationToken);
            records.Add(Record(metadata, path, usn++, UsnReason.DataOverwrite));
        }

        for (var index = count; index < count * 2; index++)
        {
            var path = files[index];
            await File.AppendAllTextAsync(path, "append", cancellationToken);
            records.Add(Record(metadata, path, usn++, UsnReason.DataExtend));
        }

        for (var index = count * 2; index < count * 3; index++)
        {
            var path = files[index];
            await using var stream = new FileStream(path, FileMode.Open, FileAccess.Write);
            stream.SetLength(Math.Max(1, stream.Length / 2));
            records.Add(Record(metadata, path, usn++, UsnReason.DataTruncation));
        }

        for (var index = count * 3; index < count * 4; index++)
        {
            var oldPath = files[index];
            var oldRecord = Record(metadata, oldPath, usn++, UsnReason.RenameOldName);
            var newPath = oldPath + ".renamed";
            File.Move(oldPath, newPath);
            records.Add(oldRecord);
            records.Add(Record(metadata, newPath, usn++, UsnReason.RenameNewName));
        }

        for (var index = count * 4; index < count * 5; index++)
        {
            var path = files[index];
            records.Add(Record(metadata, path, usn++, UsnReason.FileDelete));
            File.Delete(path);
        }

        var moveDirectory = Path.Combine(root, "유니코드");
        for (var index = count * 5; index < count * 6; index++)
        {
            var oldPath = files[index];
            var oldRecord = Record(metadata, oldPath, usn++, UsnReason.RenameOldName);
            var newPath = Path.Combine(moveDirectory, $"moved-{index:D7}.bin");
            File.Move(oldPath, newPath);
            records.Add(oldRecord);
            records.Add(Record(metadata, newPath, usn++, UsnReason.RenameNewName));
        }

        var createDirectory = Path.Combine(root, "created");
        Directory.CreateDirectory(createDirectory);
        records.Add(Record(metadata, createDirectory, usn++, UsnReason.FileCreate));
        for (var index = 0; index < count; index++)
        {
            var path = Path.Combine(createDirectory, $"new-{index:D7}.bin");
            await File.WriteAllTextAsync(path, $"created-{seed}-{index}", cancellationToken);
            records.Add(Record(metadata, path, usn++, UsnReason.FileCreate));
        }

        return records;
    }

    private static UsnRecord Record(
        WindowsFileMetadataReader metadata,
        string path,
        long usn,
        UsnReason reason)
    {
        var file = metadata.ReadPath(path);
        var parent = metadata.ReadPath(Path.GetDirectoryName(path)!);
        return new UsnRecord(
            3,
            0,
            Decode(file.Identity),
            Decode(parent.Identity),
            usn,
            DateTimeOffset.UtcNow,
            reason,
            0,
            file.Attributes,
            Path.GetFileName(path));
    }

    private static UInt128 Decode(string identity) => UInt128.Parse(
        identity[(identity.LastIndexOf(':') + 1)..],
        NumberStyles.AllowHexSpecifier,
        CultureInfo.InvariantCulture);
}
