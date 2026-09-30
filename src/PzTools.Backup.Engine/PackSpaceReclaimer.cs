using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Engine;

public sealed record PackReclamationOptions(
    bool Enabled = true,
    int SparsePercent = 50,
    int MinimumReclaimMib = 16,
    int MaximumCopyMib = 128)
{
    public void Validate()
    {
        if (SparsePercent is < 10 or > 90) throw new ArgumentOutOfRangeException(nameof(SparsePercent));
        if (MinimumReclaimMib < 1) throw new ArgumentOutOfRangeException(nameof(MinimumReclaimMib));
        if (MaximumCopyMib is < 1 or > 4096) throw new ArgumentOutOfRangeException(nameof(MaximumCopyMib));
    }
}

public sealed record PackReclamationPlan(IReadOnlyList<RepositoryPack> Packs, long PackBytes, long LiveBytes);

public sealed record PackReclamationResult(
    string Status, int RewrittenPacks, int RelocatedObjects, long ReclaimedBytes,
    IReadOnlyList<string> FilesThatCouldNotBeDeleted)
{
    public static PackReclamationResult Skipped(string reason) => new(reason, 0, 0, 0, []);
}

/// <summary>
/// A pack is deleted only when nothing in it is needed, so a backup that still needs a few files
/// from an old pack keeps all of that pack on disk. This rewrites the mostly-dead packs into one
/// new pack holding only what is still needed.
/// </summary>
public sealed class PackSpaceReclaimer(IBackupFailureInjector? failureInjector = null)
{
    /// <summary>
    /// Sparsest packs first, up to the copy budget. A rewritten pack is fully live, so it is not
    /// selected again until it has itself become sparse; the threshold bounds how often data is copied.
    /// </summary>
    public static PackReclamationPlan? Plan(IReadOnlyList<PackUsage> usage, PackReclamationOptions options)
    {
        ArgumentNullException.ThrowIfNull(usage);
        ArgumentNullException.ThrowIfNull(options);
        options.Validate();
        if (!options.Enabled) return null;
        // A pack with no live bytes is ordinary garbage; collection deletes it without a rewrite.
        var sparse = usage.Where(item => item.LiveBytes > 0 && item.Pack.ByteLength > 0
                && item.LiveBytes * 100 < item.Pack.ByteLength * options.SparsePercent)
            .OrderBy(item => (double)item.LiveBytes / item.Pack.ByteLength)
            .ThenBy(item => item.Pack.PackId).ToArray();
        if (sparse.Sum(item => item.Pack.ByteLength - item.LiveBytes) < options.MinimumReclaimMib * 1048576L)
            return null;
        var budget = options.MaximumCopyMib * 1048576L;
        var selected = new List<PackUsage>();
        foreach (var item in sparse)
        {
            // Always take the sparsest pack so one oversized pack cannot block reclamation forever.
            if (selected.Count > 0 && selected.Sum(chosen => chosen.LiveBytes) + item.LiveBytes > budget) break;
            selected.Add(item);
        }
        return new(selected.Select(item => item.Pack).ToArray(),
            selected.Sum(item => item.Pack.ByteLength), selected.Sum(item => item.LiveBytes));
    }

    /// <param name="planned">Called once work is certain, before any data is copied.</param>
    public async Task<PackReclamationResult> RunAsync(
        RepositoryDatabase repository, RepositoryWriterLease lease, PackReclamationOptions options,
        Func<PackReclamationPlan, Task>? planned = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(lease);
        if (!options.Enabled) return PackReclamationResult.Skipped("disabled");
        var plan = Plan(await repository.ReadPackUsageAsync(cancellationToken), options);
        if (plan is null) return PackReclamationResult.Skipped("below-threshold");
        // The old packs stay until the replacement has committed, so both exist for a moment.
        long? free = null;
        try { free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(repository.RepositoryPath))!).AvailableFreeSpace; }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException) { }
        if (free is null) return PackReclamationResult.Skipped("space-check-unavailable");
        if (free < plan.LiveBytes * 2 + 64 * 1048576L) return PackReclamationResult.Skipped("insufficient-space");

        if (planned is not null) await planned(plan);
        var rewritten = await new PackCompactor(failureInjector).RewriteAsync(
            repository, lease, plan.Packs, cancellationToken: cancellationToken);
        if (rewritten.NewPackId is null) return PackReclamationResult.Skipped("nothing-to-copy");
        // The replaced packs own no objects now; collection removes their rows and files.
        var garbage = await repository.CollectGarbageAsync(lease, CancellationToken.None, collectPaths: false);
        return new("Succeeded", rewritten.SourcePacks, rewritten.RelocatedObjects,
            Math.Max(0, plan.PackBytes - rewritten.NewPackBytes), garbage.FilesThatCouldNotBeDeleted);
    }
}
