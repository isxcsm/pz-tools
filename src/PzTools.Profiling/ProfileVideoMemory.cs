using System.Globalization;
using System.IO.Compression;
using System.Text;

namespace PzTools.Profiling;

/// <summary>One reading of the game's video memory, taken outside the game while it was being recorded.</summary>
public readonly record struct VideoMemoryReading(DateTimeOffset At, long Dedicated, long Shared);

/// <summary>
/// Adds video memory readings to a finished recording. The game cannot measure its own video memory, so
/// the recording worker reads it from Windows and, once the recording is written, places the readings on
/// the recording's time scale (microseconds from its first event, whose wall-clock time it records).
/// </summary>
public static class ProfileVideoMemory
{
    /// <summary>
    /// Appends the readings as one more gzip member, through a copy that replaces the file only when whole.
    /// Returns how many were added: none when there are none, or the recording has no start time.
    /// </summary>
    public static int Append(string recordingPath, IReadOnlyList<VideoMemoryReading> readings)
    {
        if (readings.Count == 0) return 0;
        var startMillis = StartEpochMillis(recordingPath);
        if (startMillis <= 0) return 0;
        var origin = startMillis * 1000;
        var staged = recordingPath + ".tmp";
        try
        {
            File.Copy(recordingPath, staged, overwrite: true);
            using (var file = new FileStream(staged, FileMode.Append, FileAccess.Write, FileShare.None))
            using (var gzip = new GZipStream(file, CompressionLevel.Optimal))
            using (var writer = new StreamWriter(gzip, new UTF8Encoding(false)))
            {
                // Should the file not end with a line break, the first reading must not join its last line.
                // The reader skips empty lines.
                writer.Write('\n');
                foreach (var reading in readings)
                {
                    var time = (reading.At.UtcTicks - DateTimeOffset.UnixEpoch.UtcTicks) / 10 - origin;
                    writer.Write(string.Create(CultureInfo.InvariantCulture,
                        $"V\t{time}\t{Math.Max(0, reading.Dedicated)}\t{Math.Max(0, reading.Shared)}\n"));
                }
            }
            File.Move(staged, recordingPath, overwrite: true);
            return readings.Count;
        }
        finally
        {
            try { File.Delete(staged); }
            catch (IOException) { }
        }
    }

    private static long StartEpochMillis(string path)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.SequentialScan);
        using var gzip = new GZipStream(file, CompressionMode.Decompress);
        using var reader = new StreamReader(gzip, Encoding.UTF8);
        const string prefix = "I\tstartEpochMillis\t";
        while (reader.ReadLine() is { } line)
            if (line.StartsWith(prefix, StringComparison.Ordinal)
                && long.TryParse(line.AsSpan(prefix.Length), NumberStyles.None, CultureInfo.InvariantCulture, out var millis))
                return millis;
        return 0;
    }
}
