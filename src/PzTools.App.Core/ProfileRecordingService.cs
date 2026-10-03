using System.Globalization;
using PzTools.Process.Contracts;
using PzTools.Profiling;

namespace PzTools.App.Core;

public enum ProfileSessionState { Idle, Starting, Recording, Converting }

/// <summary>What the recording is doing right now, as far as the worker has reported.</summary>
public sealed record ProfileSession(ProfileSessionState State, bool Detailed = false,
    DateTimeOffset? RecordingSinceUtc = null, bool LuaAvailable = true, bool HasFrames = true, int LimitSeconds = 0);

/// <param name="Summary">What the recording is, once read; null until then.</param>
public sealed record ProfileFile(string Path, string Name, DateTimeOffset CreatedUtc, long Bytes, ProfileRecordingSummary? Summary = null)
{
    /// <summary>Whether someone named it; otherwise it has the name it was saved under, "profile-" and its time.</summary>
    public bool Named => !ProfileRecordingService.IsAutomaticName(Name);
}

/// <summary>
/// The rolling recording: whether the user wants the game to keep its last minute, in which mode, and whether the
/// game is keeping it now (<see cref="On"/>, in <see cref="OnDetailed"/>). <see cref="Busy"/> while a command is under
/// way, <see cref="Saving"/> while a save is; <see cref="Error"/> is why the game is not keeping it, until it is.
/// </summary>
public sealed record ProfileRolling(bool Wanted = false, bool Detailed = false, bool On = false, bool OnDetailed = false,
    bool Busy = false, bool Saving = false, string? Error = null, int Minutes = AppSettings.DefaultRollingMinutes, int OnMinutes = 0);

/// <summary>
/// Recordings of the running game: one worker process per recording, one file per recording.
/// The files live in their own folder, outside the log and telemetry databases, so a long recording
/// cannot grow those and a single file can be handed to someone else.
/// </summary>
public sealed partial class ProfileRecordingService(string directory, Func<OperationCoordinator?> operations, Func<int>? gameCount = null,
    ProfilerRuntimeOptions? options = null)
{
    private readonly Func<int> countGames = gameCount ?? GameProcesses.Count;
    private readonly ProfilerRuntimeOptions options = options ?? new();

    /// <summary>A forgotten recording ends by itself. The detailed one is shorter: it writes about ten times as much.</summary>
    public int GeneralLimitSeconds => options.GeneralLimitMinutes * 60;
    public int DetailedLimitSeconds => options.DetailedLimitMinutes * 60;
    private readonly object gate = new();
    private ProfileSession session = new(ProfileSessionState.Idle);
    private string? stopFile;
    private Task? running;

    /// <summary>Raised on any thread whenever <see cref="Session"/> changes.</summary>
    public event Action? Changed;
    /// <summary>Raised on any thread with each recording written, a recording's or a save of the last minutes.</summary>
    public event Action<string>? Saved;
    /// <summary>
    /// The mode the next recording asked for takes, chosen on the page or by its hotkey, for as long as the app runs.
    /// A recording under way keeps the mode it started in.
    /// </summary>
    public bool PreferDetailed
    {
        get { lock (gate) return preferDetailed; }
        set
        {
            lock (gate) { if (preferDetailed == value) return; preferDetailed = value; }
            Changed?.Invoke();
        }
    }
    private bool preferDetailed;
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
            // The rolling recording goes on beside this one in the game: what it holds is still there to save.
            TryDelete(stop);
            var result = await coordinator.RecordProfileAsync(output, stop, detailed, limit, Report, cancellationToken).ConfigureAwait(false);
            var written = result.Outcome == ProcessOutcome.Succeeded && File.Exists(output);
            if (written) Saved?.Invoke(output);
            return (written ? output : null, result);
        }
        finally
        {
            TryDelete(stop);
            ReleasePath(output);
            lock (gate) { session = new(ProfileSessionState.Idle); stopFile = null; running = null; }
            completion.TrySetResult();
            Changed?.Invoke();
            WakeRolling();
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

    /// <summary>
    /// For shutdown: end a running recording, and the rolling one, so the game does not keep recording for nobody.
    /// </summary>
    public async Task StopAndWaitAsync(TimeSpan patience)
    {
        Task? task;
        lock (gate) task = running;
        var rollingStop = Rolling is { Wanted: false, On: false } && !RollingMaybeOn ? Task.CompletedTask : StopRollingAsync();
        if (task is null && rollingStop.IsCompleted) return;
        Stop();
        await Task.WhenAny(Task.WhenAll(task ?? Task.CompletedTask, rollingStop), Task.Delay(patience)).ConfigureAwait(false);
    }

    // ---- Rolling recording ----


    // How often the game is checked for while the rolling recording is wanted: a game that starts (or restarts) gets
    // it within this, whether or not a page is open.
    private static readonly TimeSpan RollingCheck = TimeSpan.FromSeconds(5);
    private readonly SemaphoreSlim rollingLock = new(1, 1);
    private ProfileRolling rolling = new();
    private CancellationTokenSource? rollingWake;
    private Task? rollingLoop;
    // A start the bridge cannot do is not retried for the same game: an old bridge or a refused attach would only fail
    // again. Others are, after a wait that grows with each failure in a row.
    private bool rollingBlocked;
    private int rollingFailures;
    private DateTime rollingRetryAt = DateTime.MinValue;
    // A start was sent to this game and no stop since: on stop and at shutdown, the game is told to stop even when the
    // start's answer never came.
    private bool rollingMaybeOn;

    private static bool IsLasting(string? error) => error is "profile-restart-required" or "profile-unsupported-protocol"
        or "profile-unsupported-runtime" or "profile-bridge-not-built" or "profile-attach-disabled"
        or PzTools.Process.Hosting.LaunchFailure.Blocked;

    // Another game, or other settings: a clean slate.
    private void ResetRollingRetries() { lock (gate) { rollingBlocked = false; rollingFailures = 0; rollingRetryAt = DateTime.MinValue; } }

    public ProfileRolling Rolling { get { lock (gate) return rolling; } }

    /// <summary>
    /// Keeps the game's last minute from now on, in the given mode, until <see cref="StopRollingAsync"/>: armed now
    /// if a game is running, otherwise as soon as one is, and again after each restart of the game. A recording asked
    /// for runs beside it.
    /// Returns the start's result when it ran now.
    /// </summary>
    public async Task<AppOperationResult?> StartRollingAsync(bool detailed, int minutes = AppSettings.DefaultRollingMinutes)
    {
        SetRolling(state => state with { Wanted = true, Detailed = detailed, Minutes = minutes, Error = null });
        ResetRollingRetries();
        // Armed here first, so the caller hears how the start went; the loop then keeps it armed.
        var result = await EnsureRollingAsync().ConfigureAwait(false);
        lock (gate) if (rolling.Wanted) rollingLoop ??= Task.Run(RollingLoopAsync);
        return result;
    }

    /// <summary>
    /// What the settings want: the last minutes kept or not, in which mode, how many. Applied in the background; one
    /// already kept in another mode or length restarts in the new one.
    /// </summary>
    public void ApplyRolling(bool enabled, bool detailed, int minutes)
    {
        if (!enabled)
        {
            if (Rolling is { Wanted: false, On: false } && !RollingMaybeOn) return;
            _ = StopRollingAsync();
            return;
        }
        bool changed;
        lock (gate)
        {
            changed = !rolling.Wanted || rolling.Detailed != detailed || rolling.Minutes != minutes;
            if (changed)
            {
                rolling = rolling with { Wanted = true, Detailed = detailed, Minutes = minutes, Error = null };
                rollingBlocked = false; rollingFailures = 0; rollingRetryAt = DateTime.MinValue;
            }
            rollingLoop ??= Task.Run(RollingLoopAsync);
        }
        if (changed) Changed?.Invoke();
        WakeRolling();
    }

    public async Task StopRollingAsync()
    {
        SetRolling(state => state with { Wanted = false, Error = null });
        WakeRolling();
        await rollingLock.WaitAsync().ConfigureAwait(false);
        try
        {
            if (!Rolling.On && !RollingMaybeOn || operations() is not { } coordinator) return;
            SetRolling(state => state with { Busy = true });
            // Whatever the answer, the app no longer counts on it; a game that has gone took it along.
            try { await coordinator.RollProfileAsync("roll-stop", false, 0).ConfigureAwait(false); }
            catch (Exception exception) when (exception is not OutOfMemoryException) { }
        }
        finally
        {
            lock (gate) rollingMaybeOn = false;
            SetRolling(state => state with { On = false, Busy = false });
            rollingLock.Release();
        }
    }

    private bool RollingMaybeOn { get { lock (gate) return rollingMaybeOn; } }

    /// <summary>
    /// Saves the last minute the game kept as a recording, and returns its file or the reason there is none. The
    /// rolling recording goes on.
    /// </summary>
    public async Task<(string? Path, AppOperationResult Result)> SaveRollingAsync(CancellationToken cancellationToken = default)
    {
        if (countGames() is var games && games != 1)
            return (null, new AppOperationResult("", 0, ProcessOutcome.Failed, null,
                games == 0 ? "profile-game-not-running" : "profile-multiple-games"));
        var coordinator = operations() ?? throw new InvalidOperationException("The application is not ready.");
        if (!await rollingLock.WaitAsync(0, cancellationToken).ConfigureAwait(false))
            return (null, new AppOperationResult("", 0, ProcessOutcome.Busy, null, "operation-busy"));
        try
        {
            SetRolling(state => state with { Busy = true, Saving = true });
            System.IO.Directory.CreateDirectory(Directory);
            var output = NextPath(DateTime.Now);
            try
            {
                var result = await coordinator.RollProfileAsync("roll-save", Rolling.OnDetailed, Math.Max(1, Rolling.OnMinutes) * 60, output,
                    cancellationToken).ConfigureAwait(false);
                // The game was not keeping it after all (the bridge was replaced, the game restarted): start it again.
                if (result.Error == "profile-not-rolling") SetRolling(state => state with { On = false });
                var written = result.Outcome == ProcessOutcome.Succeeded && File.Exists(output);
                if (written) Saved?.Invoke(output);
                return (written ? output : null, result);
            }
            finally { ReleasePath(output); }
        }
        finally
        {
            SetRolling(state => state with { Busy = false, Saving = false });
            rollingLock.Release();
            WakeRolling();
        }
    }

    /// <summary>
    /// Arms the rolling recording when it is wanted and the game is not keeping it in the wanted mode, and there is
    /// exactly one game; a recording asked for may be running beside it. Returns the start's result when one ran.
    /// </summary>
    private async Task<AppOperationResult?> EnsureRollingAsync()
    {
        if (!await rollingLock.WaitAsync(0).ConfigureAwait(false)) return null;
        try
        {
            var state = Rolling;
            if (!state.Wanted) return null;
            if (countGames() != 1)
            {
                // The game it was armed in has gone, and took the recording along: the next one gets a fresh try.
                ResetRollingRetries();
                lock (gate) rollingMaybeOn = false;
                if (state.On) SetRolling(current => current with { On = false });
                return null;
            }
            bool blocked;
            DateTime retryAt;
            lock (gate) (blocked, retryAt) = (rollingBlocked, rollingRetryAt);
            if (blocked || DateTime.UtcNow < retryAt || state.On && state.OnDetailed == state.Detailed && state.OnMinutes == state.Minutes
                || operations() is not { } coordinator) return null;
            SetRolling(current => current with { Busy = true });
            // Asked of the game from here on, whatever the answer: a stop is owed even if it never says yes.
            lock (gate) rollingMaybeOn = true;
            AppOperationResult result;
            try
            {
                result = await coordinator.RollProfileAsync("roll-start", state.Detailed, state.Minutes * 60,
                    maxMegabytes: options.RollingMaxMegabytes).ConfigureAwait(false);
            }
            catch (Exception exception) when (exception is not OutOfMemoryException)
            {
                result = new AppOperationResult("", 0, ProcessOutcome.Failed, null, "profile-failed", exception.Message);
            }
            var armed = result.Outcome == ProcessOutcome.Succeeded;
            lock (gate)
            {
                // A bridge that cannot do it waits for another game or other settings. Anything else (the channel held
                // by a backup's save, a game still starting) is tried again, less often each time.
                rollingBlocked = !armed && IsLasting(result.Error);
                rollingFailures = armed ? 0 : rollingFailures + 1;
                rollingRetryAt = armed ? DateTime.MinValue
                    : DateTime.UtcNow + TimeSpan.FromSeconds(Math.Min(300, 5 << Math.Min(6, rollingFailures)));
            }
            // A failed change of mode or length leaves the game keeping what it kept: still there to save.
            SetRolling(current => armed
                ? current with { On = true, OnDetailed = state.Detailed, OnMinutes = state.Minutes, Error = null }
                : current with { Error = result.Error ?? "profile-failed" });
            return result;
        }
        finally
        {
            SetRolling(current => current with { Busy = false });
            rollingLock.Release();
        }
    }

    private async Task RollingLoopAsync()
    {
        while (true)
        {
            CancellationTokenSource wake;
            lock (gate)
            {
                if (!rolling.Wanted) { rollingLoop = null; return; }
                wake = rollingWake = new CancellationTokenSource();
            }
            try { await EnsureRollingAsync().ConfigureAwait(false); }
            catch (Exception exception) when (exception is not OutOfMemoryException) { }
            try { await Task.Delay(RollingCheck, wake.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { }
            // Woken by a caller's cancel, the rest runs on that caller's thread; leave it at once.
            await Task.Yield();
            lock (gate) if (ReferenceEquals(rollingWake, wake)) rollingWake = null;
            wake.Dispose();
        }
    }

    // Checks now instead of at the next interval: a recording ended, a save failed, the mode changed.
    private void WakeRolling()
    {
        // Cancelled outside the lock: the loop's next pass would otherwise run inline here, holding it.
        CancellationTokenSource? wake;
        lock (gate) wake = rollingWake;
        try { wake?.Cancel(); } catch (ObjectDisposedException) { }
    }

    private void SetRolling(Func<ProfileRolling, ProfileRolling> change)
    {
        lock (gate)
        {
            var next = change(rolling);
            if (next == rolling) return;
            rolling = next;
        }
        Changed?.Invoke();
    }

    public IReadOnlyList<ProfileFile> List()
    {
        if (!System.IO.Directory.Exists(Directory)) return [];
        try
        {
            var index = Summaries();
            return new DirectoryInfo(Directory).EnumerateFiles("*" + ProfileRecording.Extension)
                .Select(file => new ProfileFile(file.FullName, System.IO.Path.GetFileNameWithoutExtension(file.Name),
                    file.LastWriteTimeUtc, file.Length, index.Find(file)))
                .OrderByDescending(file => file.CreatedUtc).ToArray();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return []; }
    }

    // ---- Names and summaries ----

    [System.Text.RegularExpressions.GeneratedRegex(@"^profile-\d{8}-\d{6}(-\d+)?$")]
    private static partial System.Text.RegularExpressions.Regex AutomaticName();

    /// <summary>A name the app gave on saving: "profile-", the date and time, and a number when two met.</summary>
    public static bool IsAutomaticName(string name) => AutomaticName().IsMatch(name);

    // What each recording is, read once and kept beside the recordings' folder (not in it: that folder is the user's),
    // by file name, size and time, so a file replaced under the same name is read again.
    private ProfileSummaryIndex? summaries;
    private readonly object summaryGate = new();
    private string SummaryIndexPath => System.IO.Path.Combine(System.IO.Path.GetDirectoryName(Directory)!, "profiles-index.json");

    private ProfileSummaryIndex Summaries()
    {
        lock (summaryGate) return summaries ??= ProfileSummaryIndex.Load(SummaryIndexPath);
    }

    /// <summary>
    /// Reads what the listed recordings without one are, in the background, and keeps it. True when any was read: the
    /// list then has more to say.
    /// </summary>
    public Task<bool> FillSummariesAsync(CancellationToken cancellationToken = default) => Task.Run(() =>
    {
        var index = Summaries();
        var read = false;
        foreach (var file in List().Where(file => file.Summary is null))
        {
            cancellationToken.ThrowIfCancellationRequested();
            ProfileRecordingSummary summary;
            try { summary = ProfileRecording.ReadSummary(file.Path); }
            catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException or FormatException)
            {
                // Not a readable recording: listed by its time alone, and not read again until it changes.
                summary = new ProfileRecordingSummary(false, false, -1);
            }
            index.Set(new FileInfo(file.Path), summary);
            read = true;
        }
        if (read) index.Save(SummaryIndexPath, Directory);
        return read;
    }, cancellationToken);

    /// <summary>
    /// Gives a listed recording a name of its own, or an automatic name (from when it was written) when
    /// <paramref name="name"/> is empty, and returns where it now is. The name is the file's: whoever is sent the file
    /// sees it too. Characters a file name cannot hold are replaced; a name already taken gets a number, the way the
    /// app numbers its own names for an automatic one, so it is still known as one.
    /// </summary>
    public string Rename(string path, string name)
    {
        var full = System.IO.Path.GetFullPath(path);
        if (!string.Equals(System.IO.Path.GetDirectoryName(full), Directory, StringComparison.OrdinalIgnoreCase)
            || !full.EndsWith(ProfileRecording.Extension, StringComparison.OrdinalIgnoreCase) || !File.Exists(full))
            throw new ArgumentException("Not a recording in the recordings folder.", nameof(path));
        var clean = CleanName(name);
        var automatic = clean.Length == 0;
        if (automatic)
        {
            var current = System.IO.Path.GetFileNameWithoutExtension(full);
            if (IsAutomaticName(current)) return full;
            clean = "profile-" + File.GetLastWriteTime(full).ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
        }
        var target = System.IO.Path.Combine(Directory, clean + ProfileRecording.Extension);
        if (string.Equals(target, full, StringComparison.Ordinal)) return full;
        // Only the letters' case differs: the same file, renamed in place.
        if (!string.Equals(target, full, StringComparison.OrdinalIgnoreCase)) target = Available(clean, automatic);
        var index = Summaries();
        var summary = index.Find(new FileInfo(full));
        File.Move(full, target);
        index.Remove(System.IO.Path.GetFileName(full));
        if (summary is not null) index.Set(new FileInfo(target), summary);
        index.Save(SummaryIndexPath);
        return target;
    }

    // The name's file, or, when taken, the name with the first number free.
    private string Available(string clean, bool automatic)
    {
        var target = System.IO.Path.Combine(Directory, clean + ProfileRecording.Extension);
        for (var suffix = 2; File.Exists(target) || IsReserved(target); suffix++)
            target = System.IO.Path.Combine(Directory, automatic ? $"{clean}-{suffix}{ProfileRecording.Extension}"
                : $"{clean} ({suffix}){ProfileRecording.Extension}");
        return target;
    }

    /// <summary>
    /// Saves a range of a listed recording, read from it as <paramref name="recording"/>, as a recording of its own
    /// named <paramref name="name"/> (with a number when taken), and returns where. See <see cref="ProfileTrim"/>.
    /// </summary>
    public string SaveRange(string path, ProfileRecording recording, long start, long end, string name,
        CancellationToken cancellationToken = default)
    {
        var full = System.IO.Path.GetFullPath(path);
        if (!string.Equals(System.IO.Path.GetDirectoryName(full), Directory, StringComparison.OrdinalIgnoreCase)
            || !full.EndsWith(ProfileRecording.Extension, StringComparison.OrdinalIgnoreCase) || !File.Exists(full))
            throw new ArgumentException("Not a recording in the recordings folder.", nameof(path));
        var clean = CleanName(name);
        if (clean.Length == 0) clean = "profile-" + DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
        var target = Available(clean, IsAutomaticName(clean));
        ProfileTrim.Save(recording, full, target, start, end, cancellationToken);
        return target;
    }

    private static string CleanName(string name)
    {
        var invalid = System.IO.Path.GetInvalidFileNameChars();
        var cleaned = new string(name.Trim().Select(character => invalid.Contains(character) ? '_' : character).ToArray()).Trim(' ', '.');
        // Windows refuses these whatever follows them.
        if (System.Text.RegularExpressions.Regex.IsMatch(cleaned, @"^(CON|PRN|AUX|NUL|COM\d|LPT\d)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
            cleaned = "_" + cleaned;
        return cleaned.Length > 80 ? cleaned[..80].TrimEnd(' ', '.') : cleaned;
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
        "profile-attach-disabled" => "ProfileError.AttachDisabled",
        "profile-restart-required" => "ProfileError.Restart",
        "profile-busy" or "operation-busy" or "profile-already-recording" => "ProfileError.Busy",
        "profile-not-rolling" => "ProfileError.NotRolling",
        "profile-convert-failed" => "ProfileError.Convert",
        "cancelled" => "OperationCancelled",
        PzTools.Process.Hosting.LaunchFailure.Blocked => "OperationError.BlockedByPolicy",
        _ => "ProfileError.Generic",
    };

    // Files handed out and not yet written: a recording's exists only once it is converted, minutes later, and a save
    // of the last minutes may start in the same second beside it.
    private readonly HashSet<string> reservedPaths = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>A free name for a new recording, held until <see cref="ReleasePath"/>.</summary>
    private string NextPath(DateTime now)
    {
        var name = "profile-" + now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
        lock (gate)
        {
            var path = System.IO.Path.Combine(Directory, name + ProfileRecording.Extension);
            for (var suffix = 2; File.Exists(path) || reservedPaths.Contains(path); suffix++)
                path = System.IO.Path.Combine(Directory, $"{name}-{suffix}{ProfileRecording.Extension}");
            reservedPaths.Add(path);
            return path;
        }
    }

    private void ReleasePath(string path) { lock (gate) reservedPaths.Remove(path); }

    private bool IsReserved(string path) { lock (gate) return reservedPaths.Contains(path); }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }
}
