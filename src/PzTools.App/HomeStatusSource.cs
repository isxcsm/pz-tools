using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Projections;
using PzTools.Zomboid.State;

namespace PzTools.App;

/// <summary>Turns the app's live views into what the Home page shows. Kept apart from the page, which reads no views.</summary>
internal static class HomeStatusSource
{
    /// <summary>
    /// The save shown is the one being played, or else the one played last; its last backup is the newest
    /// of its backups. Any view not yet available leaves its part unknown.
    /// </summary>
    public static HomeStatus From(SaveListView? saves, BackupCatalogView? catalog, GameExtensionsView? extensions, ScheduleStatusView? schedule)
    {
        var ready = saves is { LoadState: SaveListLoadState.Ready };
        var playing = saves?.Saves.FirstOrDefault(save => save.Activity == ActivityState.Active && save.Freshness == ViewFreshness.Fresh);
        var save = playing ?? saves?.Saves.Where(item => item.LastPlayedUtc is not null).MaxBy(item => item.LastPlayedUtc)
            ?? saves?.Saves.FirstOrDefault();
        DateTimeOffset? lastBackup = null;
        if (save is not null && catalog is not null)
            lastBackup = catalog.Sources
                .Where(source => StringComparer.OrdinalIgnoreCase.Equals(source.SaveId, save.SaveId))
                .SelectMany(source => source.Revisions)
                .Select(revision => (DateTimeOffset?)revision.CreatedUtc)
                .Max();
        var vehicle = extensions?.Cards.FirstOrDefault(card => card.Definition.Id == ExtensionIds.VehicleDrivetrain);
        var preference = vehicle?.VehicleDrivetrain ?? new VehicleDrivetrainPreference();
        var features = new[] { preference.TorqueEnabled, preference.ReverseEnabled, preference.SteeringEnabled, preference.AreaLightEnabled }
            .Count(enabled => enabled);
        return new HomeStatus(
            !ready ? HomeGameState.Unknown : saves!.Game switch
            {
                GameState.Playing => HomeGameState.Playing,
                GameState.NotPlaying => HomeGameState.NotPlaying,
                _ => HomeGameState.Unknown,
            },
            playing?.Name,
            schedule is { AutomaticEnabled: false },
            ready && catalog is not null,
            save?.Name, save?.Mode, lastBackup,
            vehicle is not null,
            // With the game closed its version is unknown, which is normal: still "on". Only a version
            // known not to be supported keeps a turned-on extension from applying.
            vehicle is { Enabled: true } && vehicle.StatusCode != "version-mismatch",
            vehicle is { Enabled: true, StatusCode: "version-mismatch" },
            features);
    }
}
