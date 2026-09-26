using PzTools.GameExtensions;
using PzTools.Projections;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.App.Core;

public sealed record GameExtensionsView(IReadOnlyList<ExtensionCardView> Cards, bool GameSavingEnabled, RuntimeSaveExecution? LastSave = null);

/// <summary>UI-independent controller. Disk I/O runs away from the dispatcher; only committed preferences are projected.</summary>
public sealed class GameExtensionController(string runtimeRoot, RevisionedViewStore views, Func<bool>? gameSavingEnabled = null, Func<string?>? gameVersion = null, string? cataloguePath = null, Func<RuntimeSaveExecution?>? lastSave = null)
{
    public static ViewKey ViewKey { get; } = new("game-extensions");
    private readonly GameExtensionService service = new(new ExtensionSettingsStore(runtimeRoot), gameVersion,
        cataloguePath is null ? null : () => ExtensionCatalog.ReadFile(cataloguePath));
    private IReadOnlyList<ExtensionCardView>? cachedCards;
    private readonly SemaphoreSlim gate = new(1, 1);

    public async Task<GameExtensionsView> RefreshAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try { return await Task.Run(() => Publish(service.ReadCards()), cancellationToken); }
        finally { gate.Release(); }
    }

    public async Task<GameExtensionsView> SetEnabledAsync(string id, bool enabled, long expectedRevision,
        CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            // Cancellation is checked before admission, never reported after a preference already committed.
            return await Task.Run(() => Publish(service.SetEnabled(id, enabled, expectedRevision)), cancellationToken);

        }
        finally { gate.Release(); }
    }

    public async Task<GameExtensionsView> SetPreferenceAsync(string id, bool enabled, bool forceVersion,
        long expectedRevision, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try { return await Task.Run(() => Publish(service.SetPreference(id, enabled, forceVersion, expectedRevision)), cancellationToken); }
        finally { gate.Release(); }
    }
    public async Task RefreshRuntimeAsync(CancellationToken token)
    {
        if (!await gate.WaitAsync(0, token)) return;
        try
        {
            if (cachedCards is null) return;
            var version = gameVersion?.Invoke();
            Publish(cachedCards.Select(card => card.WithVersion(version)).ToArray());
        }
        finally { gate.Release(); }
    }
    private GameExtensionsView Publish(IReadOnlyList<ExtensionCardView> cards)
    {
        cachedCards = cards;
        var view = new GameExtensionsView(cards, gameSavingEnabled?.Invoke() ?? true, lastSave?.Invoke());
        views.Publish(ViewKey, view, comparer: new ViewComparer());
        return view;
    }
    private sealed class ViewComparer : IEqualityComparer<GameExtensionsView>
    {
        public bool Equals(GameExtensionsView? x, GameExtensionsView? y) =>
            ReferenceEquals(x, y) || x is not null && y is not null && x.GameSavingEnabled == y.GameSavingEnabled && x.LastSave == y.LastSave && x.Cards.SequenceEqual(y.Cards);
        public int GetHashCode(GameExtensionsView obj) => obj.Cards.Count;
    }
}
