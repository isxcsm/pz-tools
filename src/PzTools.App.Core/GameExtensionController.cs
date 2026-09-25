using PzTools.GameExtensions;
using PzTools.Projections;

namespace PzTools.App.Core;

public sealed record GameExtensionsView(IReadOnlyList<ExtensionCardView> Cards);

/// <summary>UI-independent controller. Disk I/O runs away from the dispatcher; only committed preferences are projected.</summary>
public sealed class GameExtensionController(string runtimeRoot, RevisionedViewStore views)
{
    public static ViewKey ViewKey { get; } = new("game-extensions");
    private readonly GameExtensionService service = new(new ExtensionSettingsStore(runtimeRoot));
    private readonly SemaphoreSlim gate = new(1, 1);

    public async Task<GameExtensionsView> RefreshAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try { return Publish(await Task.Run(service.ReadCards, cancellationToken)); }
        finally { gate.Release(); }
    }

    public async Task<GameExtensionsView> SetEnabledAsync(string id, bool enabled, long expectedRevision,
        CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            // Cancellation is checked before admission, never reported after a preference already committed.
            var cards = await Task.Run(() => service.SetEnabled(id, enabled, expectedRevision), cancellationToken);
            return Publish(cards);
        }
        finally { gate.Release(); }
    }

    private GameExtensionsView Publish(IReadOnlyList<ExtensionCardView> cards)
    {
        var view = new GameExtensionsView(cards);
        views.Publish(ViewKey, view, comparer: new ViewComparer());
        return view;
    }
    private sealed class ViewComparer : IEqualityComparer<GameExtensionsView>
    {
        public bool Equals(GameExtensionsView? x, GameExtensionsView? y) =>
            ReferenceEquals(x, y) || x is not null && y is not null && x.Cards.SequenceEqual(y.Cards);
        public int GetHashCode(GameExtensionsView obj) => obj.Cards.Count;
    }
}
