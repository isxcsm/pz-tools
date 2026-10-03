using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PzTools.App.Core;
using PzTools.Process.Contracts;
using PzTools.Projections;
using PzTools.Zomboid.State;

namespace PzTools.App;

/// <summary>
/// The app's actions from inside the game, on the key combinations the settings give them, taken from Windows while
/// the app runs. The player sees none of the app there, so each answers with a sound and, where the game can show one,
/// a note over the character; what went wrong waits in the app.
/// </summary>
internal sealed class HotKeyController : IDisposable
{
    private readonly App app;
    private readonly GlobalHotKeys keys;
    private IReadOnlyList<HotKeyAction> refused = [];
    // Each action once at a time: a second press while it runs is answered, not queued.
    private readonly HashSet<HotKeyAction> running = [];

    public HotKeyController(App app, Window window)
    {
        this.app = app;
        keys = new GlobalHotKeys(window, action => _ = RunAsync(action));
    }

    /// <summary>Raised on the window's thread when the combinations in force change.</summary>
    public event Action? Changed;

    /// <summary>The actions whose combination another program holds.</summary>
    public IReadOnlyList<HotKeyAction> Refused => refused;

    /// <summary>The combination in force for an action, as written, or null.</summary>
    public string? TextOf(HotKeyAction action) => keys.Registered.TryGetValue(action, out var gesture) ? gesture.ToString() : null;

    /// <summary>Whether no other program holds the combination now.</summary>
    public bool IsFree(HotKeyGesture gesture) => keys.IsFree(gesture);

    /// <summary>
    /// Takes the settings' combinations. Saving the last minutes is taken only while the game keeps them, as there is
    /// nothing to save otherwise; every combination is taken from all other programs while it is held.
    /// </summary>
    public void Apply(AppSettings settings)
    {
        applied = settings;
        if (suspended) return;
        var wanted = settings.Keys.Gestures()
            .Where(item => item.Key != HotKeyAction.SaveLast || settings.RollingEnabled)
            .ToDictionary(item => item.Key, item => item.Value);
        refused = keys.Apply(wanted);
        Changed?.Invoke();
    }

    private AppSettings? applied;
    private bool suspended;

    /// <summary>Gives every combination back while one is being chosen, so the keys pressed reach the settings.</summary>
    public void Suspend()
    {
        suspended = true;
        keys.Apply(new Dictionary<HotKeyAction, HotKeyGesture>());
    }

    public void Resume()
    {
        if (!suspended) return;
        suspended = false;
        if (applied is { } settings) Apply(settings);
    }

    public void Dispose() => keys.Dispose();

    private async Task RunAsync(HotKeyAction action)
    {
        if (app.Host is not { } host) { Sound(SystemSound.Failed); return; }
        // A recording runs until the same key stops it: the recording's own state answers a second press.
        var guarded = action != HotKeyAction.Record;
        if (guarded && !running.Add(action)) { Sound(SystemSound.Failed); return; }
        try
        {
            switch (action)
            {
                case HotKeyAction.SaveLast: await SaveLastAsync(host); break;
                case HotKeyAction.Record: await RecordAsync(host); break;
                case HotKeyAction.RecordMode: ToggleMode(host); break;
                case HotKeyAction.RollingToggle: await ToggleRollingAsync(host); break;
                case HotKeyAction.ManualBackup: await BackupAsync(host); break;
                case HotKeyAction.BackupToggle: await ToggleBackupsAsync(host); break;
                default: await StatusAsync(host); break;
            }
        }
        catch (Exception exception)
        {
            Sound(SystemSound.Failed);
            app.ShowSidebarNotification(InfoBarSeverity.Error, Localizer.Get("HotKeysTitle"), UserFacingError.FromException(exception));
        }
        finally { if (guarded) running.Remove(action); }
    }

    private void Sound(Action play)
    {
        if (app.Host?.RuntimeOptions.HotKeyOptions.Sounds != false) play();
    }

    // The note goes on by itself; nothing waits for the game to show it.
    private static void Note(AppHost host, params string[] items) => _ = host.NotifyGameAsync(items);

    private async Task SaveLastAsync(AppHost host)
    {
        var profiles = host.Profiles;
        if (profiles.Rolling is not { On: true, Busy: false } rolling)
        {
            Sound(SystemSound.Failed);
            Note(host, "save-last-none");
            app.ShowSidebarNotification(InfoBarSeverity.Informational, Localizer.Get("ProfilerNavigation"),
                Localizer.Get("ProfileRollingNotReady"));
            return;
        }
        Sound(SystemSound.Accepted);
        var (path, result) = await profiles.SaveRollingAsync();
        if (path is null)
        {
            Sound(SystemSound.Failed);
            Note(host, "save-last-failed");
            Explain(result);
            return;
        }
        Sound(SystemSound.Done);
        Note(host, $"saved-last:{Math.Max(1, rolling.OnMinutes)}");
    }

    private async Task RecordAsync(AppHost host)
    {
        var profiles = host.Profiles;
        switch (profiles.Session.State)
        {
            case ProfileSessionState.Recording:
                profiles.Stop();
                Sound(SystemSound.Accepted);
                Note(host, "recording-stopped");
                return;
            case not ProfileSessionState.Idle:
                Sound(SystemSound.Failed);
                Note(host, "busy");
                return;
        }
        if (host.Operations is null) { Sound(SystemSound.Failed); return; }
        var detailed = profiles.PreferDetailed;
        Sound(SystemSound.Accepted);
        Note(host, detailed ? "recording-detailed" : "recording-standard");
        // Runs until the same key, the page's button, the time limit or the game's exit ends it.
        var (path, result) = await profiles.RecordAsync(detailed);
        if (path is null)
        {
            Sound(SystemSound.Failed);
            Note(host, "recording-failed");
            Explain(result);
            return;
        }
        Sound(SystemSound.Done);
        Note(host, "recording-saved");
    }

    // Standard or Detailed for the next recording; one under way keeps its own, so the note names the next.
    private void ToggleMode(AppHost host)
    {
        var profiles = host.Profiles;
        profiles.PreferDetailed = !profiles.PreferDetailed;
        Sound(SystemSound.Accepted);
        Note(host, profiles.PreferDetailed ? "next-recording-detailed" : "next-recording-standard");
    }

    private async Task ToggleRollingAsync(AppHost host)
    {
        var settings = host.Settings.Load();
        var next = settings with { RollingEnabled = !settings.RollingEnabled };
        await app.ApplySettingsAsync(next);
        Sound(SystemSound.Accepted);
        Note(host, next.RollingEnabled ? $"rolling-on:{next.RollingMinutes}" : "rolling-off");
    }

    private async Task BackupAsync(AppHost host)
    {
        if (host.Operations is not { } operations) { Sound(SystemSound.Failed); return; }
        var saves = host.Views.ReadIfChanged<SaveListView>(ViewKey.SaveList, 0).Snapshot;
        var schedule = host.Views.ReadIfChanged<ScheduleStatusView>(ViewKey.ScheduleStatus, 0).Snapshot;
        // The save being played; otherwise the one the scheduler backs up.
        var playing = saves?.Saves.FirstOrDefault(save => save.Activity == ActivityState.Active && save.Freshness == ViewFreshness.Fresh);
        var (saveId, source) = playing is not null ? (playing.SaveId, playing.SourcePath)
            : schedule?.CurrentTarget is { } target ? (target.SaveId, target.SourcePath) : (null, null);
        if (saveId is null || source is null)
        {
            Sound(SystemSound.Failed);
            app.ShowSidebarNotification(InfoBarSeverity.Informational, Localizer.Get("HotKeysTitle"), Localizer.Get("HotKeyNoSave"));
            return;
        }
        if (host.HasRunningOperation())
        {
            Sound(SystemSound.Failed);
            Note(host, "busy");
            return;
        }
        Sound(SystemSound.Accepted);
        // Before the backup asks the game to save: the note would otherwise wait for the save to finish. Not for
        // long, though: a game that does not answer must not hold the backup up.
        await Task.WhenAny(host.NotifyGameAsync(["backup-started"]), Task.Delay(TimeSpan.FromSeconds(3)));
        var result = await operations.BackupAsync(saveId, source);
        if (result.Outcome is ProcessOutcome.Succeeded or ProcessOutcome.NoChange)
        {
            Sound(SystemSound.Done);
            Note(host, "backup-done");
        }
        else
        {
            // The backup's own card says why; the player hears it and reads the note.
            Sound(SystemSound.Failed);
            Note(host, result.Outcome == ProcessOutcome.Busy ? "busy" : "backup-failed");
        }
    }

    // The settings' own switch, as if flipped there: nothing else holds backups back, and nothing turns them on again
    // by itself.
    private async Task ToggleBackupsAsync(AppHost host)
    {
        var settings = host.Settings.Load();
        var next = settings with { AutomaticBackupEnabled = !settings.AutomaticBackupEnabled };
        await app.ApplySettingsAsync(next);
        Sound(SystemSound.Accepted);
        Note(host, next.AutomaticBackupEnabled ? "backups-on" : "backups-off");
    }

    private Task StatusAsync(AppHost host)
    {
        var now = DateTimeOffset.UtcNow;
        var schedule = host.Views.ReadIfChanged<ScheduleStatusView>(ViewKey.ScheduleStatus, 0).Snapshot;
        var saves = host.Views.ReadIfChanged<SaveListView>(ViewKey.SaveList, 0).Snapshot;
        var catalog = host.Views.ReadIfChanged<BackupCatalogView>(ViewKey.BackupCatalog, 0).Snapshot;
        var items = new List<string>();
        if (schedule is { AutomaticEnabled: false }) items.Add("backups-off");
        else if (ScheduleCountdownPresentation.Resolve(schedule, now).RemainingSeconds is { } seconds)
            items.Add(seconds < 60 ? "next-backup-soon" : $"next-backup:{Minutes(seconds)}");
        var home = HomeStatusSource.From(saves, catalog, null, schedule);
        if (home.LastBackupUtc is { } last) items.Add($"last-backup:{(int)Math.Max(0, (now - last).TotalMinutes)}");
        else if (home.SavesKnown) items.Add("last-backup-none");
        // Both, as the last minutes are kept through a recording.
        if (host.Profiles.Session.State == ProfileSessionState.Recording) items.Add("recording-now");
        if (host.Profiles.Rolling is { On: true } rolling) items.Add($"rolling-on:{Math.Max(1, rolling.OnMinutes)}");
        Sound(SystemSound.Accepted);
        if (items.Count > 0) Note(host, [.. items.Take(GameNoticeLimit)]);
        return Task.CompletedTask;
    }

    // As many notes as the game puts in one line.
    private const int GameNoticeLimit = 4;

    private static long Minutes(double seconds) => (long)Math.Ceiling(seconds / 60);

    // A failure the player cannot read in the game: on the work's own card, or beside it when none ran.
    private void Explain(AppOperationResult result)
    {
        var message = Localizer.Get(ProfileRecordingService.ErrorKey(result));
        if (result.RunIndex > 0) app.ExplainOnOperationCard(result.OperationId, message);
        else app.ShowSidebarNotification(InfoBarSeverity.Informational, Localizer.Get("ProfilerNavigation"), message);
    }
}
