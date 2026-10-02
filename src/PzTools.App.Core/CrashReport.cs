using System.Globalization;
using System.Text;

namespace PzTools.App.Core;

/// <summary>
/// The last thing a dying app does: leave the reason where a user can find and send it. Plain
/// files, because the log database may be the very thing that failed.
/// </summary>
public static class CrashReport
{
    public const int RetainedReports = 20;

    /// <summary>Returns the written file, or null when even that was impossible. Never throws.</summary>
    public static string? TryWrite(string directory, string origin, Exception? exception, DateTimeOffset now)
    {
        try
        {
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory,
                $"crash-{now.UtcDateTime.ToString("yyyyMMdd-HHmmss-fff", CultureInfo.InvariantCulture)}.txt");
            var text = new StringBuilder()
                .AppendLine($"PZ Tools {typeof(CrashReport).Assembly.GetName().Version}")
                .AppendLine($"Time (UTC): {now.UtcDateTime.ToString("O", CultureInfo.InvariantCulture)}")
                .AppendLine($"Origin: {origin}")
                .AppendLine($"OS: {Environment.OSVersion}")
                .AppendLine()
                .AppendLine(exception?.ToString() ?? "No exception object was provided.");
            File.WriteAllText(path, text.ToString(), new UTF8Encoding(false));
            foreach (var old in Directory.GetFiles(directory, "crash-*.txt")
                         .OrderByDescending(file => file, StringComparer.OrdinalIgnoreCase).Skip(RetainedReports))
            {
                try { File.Delete(old); }
                catch (Exception failure) when (failure is IOException or UnauthorizedAccessException) { }
            }
            return path;
        }
        catch (Exception)
        {
            return null;
        }
    }
}
