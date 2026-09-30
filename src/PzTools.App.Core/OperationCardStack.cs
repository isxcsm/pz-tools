using PzTools.Projections;

namespace PzTools.App.Core;

public enum OperationCardGroup { Backup, Restore, Export, Import, CharacterRecovery, DeleteSave, Maintenance, Profile, Notice }

/// <summary>Ascending order is the stacking order: a higher tier sits lower, next to the fixed schedule line.</summary>
public enum OperationCardTier { Other, Backup, User }

/// <param name="Title">Set for a notice, whose title is given by the action that raised it.</param>
public sealed record OperationCard(string Key, OperationCardGroup Group, OperationCardTier Tier, OperationView Operation,
    string? Title = null);

/// <summary>
/// The immediate result of something the user did that runs no worker: a rename, a deletion, a setting that could
/// not be saved, work refused before it started. It sits with the user's work and expires like a finished card.
/// </summary>
public sealed record OperationNotice(string Id, string Title, string Message, OperationStatus Status, DateTimeOffset ShownUtc)
{
    public OperationView ToView() => new("notice", Id, "notice", "app", 0, Status, null, 0, null, 0, null,
        TelemetryHealth.Healthy, Message, ShownUtc);
}

/// <summary>Work the app showed through its own placeholder card, which has since expired.</summary>
public sealed record RetiredWork(string OperationId, long RunIndex, DateTimeOffset RetiredUtc);

/// <summary>
/// One card per piece of work as the user sees it, not per process. Cards are listed top to bottom:
/// background cleanup, then automatic backups, then what the user asked for; within a tier a newer
/// card enters at the bottom and pushes older ones up.
/// </summary>
public static class OperationCardStack
{
    public const int DefaultLimit = 4;
    private const string LocalKey = "local";

    public static OperationCardGroup? GroupOf(OperationView operation)
    {
        if (operation.Producer.StartsWith("maintenance", StringComparison.Ordinal)
            || operation.Kind.StartsWith("maintenance", StringComparison.Ordinal)) return OperationCardGroup.Maintenance;
        return operation.Kind switch
        {
            "delete-save" => OperationCardGroup.DeleteSave,
            "character-recovery" => OperationCardGroup.CharacterRecovery,
            "profile" => OperationCardGroup.Profile,
            "export" => OperationCardGroup.Export,
            "import" => OperationCardGroup.Import,
            var kind when kind.Contains("restore", StringComparison.OrdinalIgnoreCase) => OperationCardGroup.Restore,
            var kind when kind.Contains("backup", StringComparison.OrdinalIgnoreCase) => OperationCardGroup.Backup,
            _ => null,
        };
    }

    /// <summary>
    /// What is left of the projected operations at <paramref name="now"/>. A finished operation leaves once its
    /// lifetime has passed, even if the projection that listed it is older than that; and work whose result the
    /// app already showed on its own placeholder card never comes back as a second card for the same work.
    /// </summary>
    public static OperationsView Visible(OperationsView view, IReadOnlyCollection<RetiredWork> retired,
        DateTimeOffset now, TimeSpan successLifetime, TimeSpan failureLifetime) =>
        new(view.Operations
            .Where(operation => !retired.Any(work => work.OperationId == operation.OperationId
                || work.RunIndex > 0 && work.RunIndex == operation.RunIndex))
            .Where(operation => !OperationCardLifetime.IsExpired(operation.Status, operation.CompletedUtc, now,
                GroupOf(operation) == OperationCardGroup.Maintenance, successLifetime, failureLifetime))
            .ToArray());

    /// <param name="local">The app's own placeholder for work the user just started, shown until the worker reports.</param>
    /// <param name="localBaselineRunIndex">Highest run index that existed before <paramref name="local"/> started.</param>
    /// <param name="notices">Immediate results of the user's actions, oldest first; they sit below the placeholder.</param>
    public static IReadOnlyList<OperationCard> Build(OperationsView view, OperationView? local,
        long localBaselineRunIndex, int limit = DefaultLimit, IReadOnlyList<OperationNotice>? notices = null)
    {
        var projected = view.Operations
            .Select(operation => (Operation: operation, Group: GroupOf(operation)))
            .Where(item => item.Group is not null)
            .Select(item => (item.Operation, Group: item.Group!.Value)).ToList();
        var cards = new List<(OperationCard Card, long Order, long Then)>();

        if (local is not null && GroupOf(local) is { } localGroup)
        {
            // A running placeholder gives way only to its own worker's new run. A finished one keeps
            // the result the app observed; a stale projection of the same work cannot reopen it.
            var shown = local.Status != OperationStatus.Running ? local
                : projected.Where(item => item.Group == localGroup
                        && item.Operation.OperationId == local.OperationId
                        && item.Operation.RunIndex > localBaselineRunIndex)
                    .Select(item => item.Operation).MaxBy(operation => operation.RunIndex) ?? local;
            projected.RemoveAll(item => item.Operation.OperationId == local.OperationId
                || item.Group == localGroup && item.Operation.RunIndex > 0
                    && (item.Operation.RunIndex == local.RunIndex || item.Operation.RunIndex == shown.RunIndex));
            cards.Add((new(LocalKey, localGroup, OperationCardTier.User, shown), long.MaxValue, 0));
        }

        // The user's newest action is closest to the schedule line: notices come after the placeholder.
        foreach (var notice in notices ?? [])
            cards.Add((new($"notice:{notice.Id}", OperationCardGroup.Notice, OperationCardTier.User, notice.ToView(), notice.Title),
                long.MaxValue, notice.ShownUtc.UtcTicks));

        var maintenance = projected.Where(item => item.Group == OperationCardGroup.Maintenance)
            .Select(item => item.Operation).ToArray();
        if (maintenance.Length > 0)
        {
            // Separate cleanup processes are one "cleanup" to the user: working while any of them works.
            var shown = maintenance.OrderByDescending(IsActive)
                .ThenByDescending(operation => operation.CompletedUtc ?? DateTimeOffset.MaxValue)
                .ThenByDescending(operation => operation.RunIndex).First();
            cards.Add((new("maintenance", OperationCardGroup.Maintenance, OperationCardTier.Other, shown), shown.RunIndex, 0));
        }

        foreach (var run in projected.Where(item => item.Group == OperationCardGroup.Backup)
                     .GroupBy(item => item.Operation.RunIndex))
        {
            // Scheduler, runner and worker of one backup share its run index.
            var shown = run.Select(item => item.Operation).OrderByDescending(IsActive)
                .ThenByDescending(operation => operation.Producer == "backup-worker").First();
            var tier = run.Any(item => item.Operation.Kind == "backup") ? OperationCardTier.User : OperationCardTier.Backup;
            cards.Add((new($"backup:{run.Key}", OperationCardGroup.Backup, tier, shown), run.Key, 0));
        }

        foreach (var item in projected.Where(item => item.Group is not (OperationCardGroup.Maintenance or OperationCardGroup.Backup)))
            cards.Add((new($"{item.Group}:{item.Operation.OperationId}", item.Group, OperationCardTier.User, item.Operation),
                item.Operation.RunIndex, 0));

        var ordered = cards.DistinctBy(item => item.Card.Key)
            .OrderBy(item => item.Card.Tier).ThenBy(item => item.Order).ThenBy(item => item.Then)
            .Select(item => item.Card).ToList();
        // Over the limit, finished cards go first, least important and oldest first. Active work always stays.
        while (ordered.Count > Math.Max(1, limit) && ordered.FindIndex(card => !IsActive(card.Operation)) is >= 0 and var index)
            ordered.RemoveAt(index);
        return ordered;
    }

    private static bool IsActive(OperationView operation) =>
        operation.Status is OperationStatus.Running or OperationStatus.Waiting;
}
