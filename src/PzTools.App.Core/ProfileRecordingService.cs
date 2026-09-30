using System.Globalization;
using PzTools.Process.Contracts;
using PzTools.Profiling;

namespace PzTools.App.Core;

public enum ProfileSessionState { Idle, Starting, Recording, Converting }

/// <summary>What the recording is doing right now, as far as the worker has reported.</summary>
public sealed record ProfileSession(ProfileSessionState State, bool Detailed = false,
    DateTimeOffset? RecordingSinceUtc = null, bool LuaAvailable = true, bool HasFrames = true, int LimitSeconds = 0);

public sealed record ProfileFile(string Path, string Name, DateTimeOffset CreatedUtc, long Bytes);

/// <summary>
/// Recordings of the running game: one worker process per recording, one file per recording.
/// The files live in their own folder, outside the log and telemetry databases, so a long recording
/// cannot grow those and a single file can be handed to someone else.
/// </summary>
public sealed class ProfileRecordingService(string directory, Func<OperationCoordinator?> operations, Func<int>? gameCount = null)
{
    private readonly Func<int> countGames = gameCount ?? GameProcesses.Count;

    /// <summary>A forgotten recording ends by itself. The detailed one is shorter: it writes about ten times as much.</summary>
    public const int GeneralLimitSeconds = 1800, DetailedLimitSeconds = 600;
    private readonly object gate = new();
    private ProfileSession session = new(ProfileSessionState.Idle);
    private string? stopFile;
    private Task? running;

    /// <summary>Raised on any thread whenever <see cref="Session"/> changes.</summary>
    public event Action? Changed;
    public string Directory { get; } = Path.GetFullPath(directory);
    public ProfileSession Session { get { lock (gate) return session; } }

    /// <summary>How many games are running now. A recording needs exactly one.</summary>
    public int RunningGames() => countGames();

    /// <summary>Runs one recording to its end and returns the finished file, or the reason there is none.</summary>
    public async Task<(string? Path, AppOperationResult Result)> RecordAsync(bool detailed, CancellationToken cancellationToken = default)
    {
        // Without exactly one game there is nothing to record. Say so without starting a worker: that is
        // not a failure, and it must not leave a failed run in the logs.
        if (countGames() is var games && games != 1)
            return (null, new AppOperationResult("", 0, ProcessOutcome.Failed, null,
                games == 0 ? "profile-game-not-running" : "profile-multiple-games"));
        var coordinator = operations() ?? throw new InvalidOperationException("The application is not ready.");
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        string output, stop;
        var limit = detailed ? DetailedLimitSeconds : GeneralLimitSeconds;
        lock (gate)
        {
            if (session.State != ProfileSessionState.Idle)
                return (null, new AppOperationResult("", 0, ProcessOutcome.Busy, null, "operation-busy"));
            System.IO.Directory.CreateDirectory(Directory);
            output = NextPath(DateTime.Now);
            stop = stopFile = output + ".stop";
            session = new(ProfileSessionState.Starting, detailed, LimitSeconds: limit);
            running = completion.Task;
        }
        Changed?.Invoke();
        try
        {
            TryDelete(stop);
            var result = await coordinator.RecordProfileAsync(output, stop, detailed, limit, Report, cancellationToken).ConfigureAwait(false);
            return (result.Outcome == ProcessOutcome.Succeeded && File.Exists(output) ? output : null, result);
        }
        finally
        {
            TryDelete(stop);
            lock (gate) { session = new(ProfileSessionState.Idle); stopFile = null; running = null; }
            completion.TrySetResult();
            Changed?.Invoke();
        }

        void Report(string line)
        {
            var fields = line.Split('\t');
            lock (gate)
            {
                if (fields is ["recording", var lua, var frames])
                    session = session with
                    {
                        State = ProfileSessionState.Recording, RecordingSinceUtc = DateTimeOffset.UtcNow,
                        LuaAvailable = lua == "sampling", HasFrames = frames == "frames",
                    };
                else if (fields is ["converting"]) session = session with { State = ProfileSessionState.Converting };
                else return;
            }
            Changed?.Invoke();
        }
    }

    /// <summary>Asks the running recording to finish. The file is ready when <see cref="RecordAsync"/> returns.</summary>
    public void Stop()
    {
        string? path;
        lock (gate) path = stopFile;
        if (path is null) return;
        try { File.WriteAllText(path, ""); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>For shutdown: end a running recording so the game does not keep recording for nobody.</summary>
    public async Task StopAndWaitAsync(TimeSpan patience)
    {
        Task? task;
        lock (gate) task = running;
        if (task is null) return;
        Stop();
        await Task.WhenAny(task, Task.Delay(patience)).ConfigureAwait(false);
    }

    public IReadOnlyList<ProfileFile> List()
    {
        if (!System.IO.Directory.Exists(Directory)) return [];
        try
        {
            return new DirectoryInfo(Directory).EnumerateFiles("*" + ProfileRecording.Extension)
                .Select(file => new ProfileFile(file.FullName, System.IO.Path.GetFileNameWithoutExtension(file.Name),
                    file.LastWriteTimeUtc, file.Length))
                .OrderByDescending(file => file.CreatedUtc).ToArray();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return []; }
    }

    public void Delete(string path)
    {
        // Only a recording inside the recordings folder; the path comes back from the list shown to the user.
        var full = System.IO.Path.GetFullPath(path);
        if (!string.Equals(System.IO.Path.GetDirectoryName(full), Directory, StringComparison.OrdinalIgnoreCase)
            || !full.EndsWith(ProfileRecording.Extension, StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Not a recording in the recordings folder.", nameof(path));
        File.Delete(full);
    }

    /// <summary>
    /// Copies a recording from anywhere into the recordings folder, so it is listed with the others, and returns
    /// where it now is. A file that is not a readable recording is refused before anything is copied.
    /// </summary>
    public string Import(string source)
    {
        var full = System.IO.Path.GetFullPath(source);
        if (!full.EndsWith(ProfileRecording.Extension, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Not a performance recording.");
        if (string.Equals(System.IO.Path.GetDirectoryName(full), Directory, StringComparison.OrdinalIgnoreCase)) return full;
        _ = ProfileRecording.Load(full);
        System.IO.Directory.CreateDirectory(Directory);
        var name = System.IO.Path.GetFileNameWithoutExtension(full);
        var target = System.IO.Path.Combine(Directory, name + ProfileRecording.Extension);
        for (var suffix = 2; File.Exists(target); suffix++)
            target = System.IO.Path.Combine(Directory, $"{name}-{suffix}{ProfileRecording.Extension}");
        // Keeps the file's own time, so the list shows when it was recorded, not when it was brought in.
        File.Copy(full, target);
        return target;
    }

    /// <summary>Copies one of the listed recordings to a place the user chose.</summary>
    public void Export(string recording, string destination)
    {
        var full = System.IO.Path.GetFullPath(recording);
        if (!string.Equals(System.IO.Path.GetDirectoryName(full), Directory, StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Not a recording in the recordings folder.", nameof(recording));
        var target = System.IO.Path.GetFullPath(destination);
        if (string.Equals(full, target, StringComparison.OrdinalIgnoreCase)) return;
        File.Copy(full, target, overwrite: true);
    }

    /// <summary>The resource key that explains a failed recording to the user.</summary>
    public static string ErrorKey(AppOperationResult result) => ErrorKey(result.Error);

    public static string ErrorKey(string? error) => error switch
    {
        "profile-game-not-running" => "ProfileError.GameNotRunning",
        "profile-multiple-games" => "ProfileError.MultipleGames",
        "profile-attach-failed" or "profile-connection-timeout" or "profile-bridge-not-built"
            or "profile-unsupported-protocol" or "profile-unsupported-runtime" => "ProfileError.Link",
        "profile-busy" or "operation-busy" => "ProfileError.Busy",
        "profile-convert-failed" => "ProfileError.Convert",
        "cancelled" => "OperationCancelled",
        PzTools.Process.Hosting.LaunchFailure.Blocked => "OperationError.BlockedByPolicy",
        _ => "ProfileError.Generic",
    };

    private string NextPath(DateTime now)
    {
        var name = "profile-" + now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
        var path = System.IO.Path.Combine(Directory, name + ProfileRecording.Extension);
        for (var suffix = 2; File.Exists(path); suffix++)
            path = System.IO.Path.Combine(Directory, $"{name}-{suffix}{ProfileRecording.Extension}");
        return path;
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }
}
