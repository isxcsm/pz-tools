using PzTools.GameExtensions;
using PzTools.Projections;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.App.Core;

public sealed record GameExtensionsView(IReadOnlyList<ExtensionCardView> Cards, bool GameSavingEnabled,
    RuntimeSaveExecution? LastSave = null, IReadOnlyDictionary<string, RuntimeExtensionStatus>? Statuses = null, bool RuntimeWorldReady = false)
{
    /// <summary>What the game reports for one continuous module; null when nothing current is known.</summary>
    public RuntimeExtensionStatus? StatusOf(string extensionId) => Statuses?.GetValueOrDefault(extensionId);
    public ExtensionActivationView ActivationFor(ExtensionCardView card) =>
        // Capability decides behavior; runtime evidence still belongs to one specific module.
        ExtensionActivationView.Project(card, GameSavingEnabled, RuntimeWorldReady, StatusOf(card.Definition.Id));
}

/// <summary>UI-independent controller. Disk I/O runs away from the dispatcher; only committed preferences are projected.</summary>
public sealed class GameExtensionController(string runtimeRoot, RevisionedViewStore views, Func<bool>? gameSavingEnabled = null, Func<string?>? gameVersion = null, string? cataloguePath = null, Func<RuntimeSaveExecution?>? lastSave = null, Func<string, RuntimeExtensionStatus?>? extensionStatus = null, Func<bool>? runtimeWorldReady = null, ExtensionRuntimeDiagnostics? diagnostics = null)
{
    public static ViewKey ViewKey { get; } = new("game-extensions");
    private GameExtensionService? service;
    // Reads the deployed catalogue through the cache below: an edit reads it once, not once per step.
    private GameExtensionService Service => service ??= new(new ExtensionSettingsStore(runtimeRoot), gameVersion,
        cataloguePath is null ? null : Catalogue);
    private readonly string settingsPath = new ExtensionSettingsStore(runtimeRoot).FilePath;
    private IReadOnlyList<ExtensionCardView>? cachedCards;
    // What the cards are read from. The runtime refresh runs every second for the life of the app;
    // while the settings file, the catalogue and the game version are as they were, the cards are too.
    private (DateTime, long, DateTime, long, string?)? cardInputs;
    private readonly SemaphoreSlim gate = new(1, 1);
    // The deployed catalogue as last read, with the file's time and length then; reread only when they change.
    private (DateTime Written, long Length, IReadOnlyList<ExtensionDefinition> Definitions)? catalogue;

    /// <summary>The deployed catalogue (the one the cards and the game read), or the built-in one without a file.</summary>
    private IReadOnlyList<ExtensionDefinition> Catalogue()
    {
        if (cataloguePath is null) return ExtensionCatalog.BuiltIn;
        var file = new FileInfo(cataloguePath);
        var stamp = (file.Exists ? file.LastWriteTimeUtc : default, file.Exists ? file.Length : -1);
        if (catalogue is { } known && (known.Written, known.Length) == stamp) return known.Definitions;
        var definitions = ExtensionCatalog.ReadFile(cataloguePath);
        catalogue = (stamp.Item1, stamp.Item2, definitions);
        return definitions;
    }

    private (DateTime, long, DateTime, long, string?)? CardInputs()
    {
        try
        {
            var settings = new FileInfo(settingsPath);
            var catalogue = cataloguePath is null ? null : new FileInfo(cataloguePath);
            return (settings.Exists ? settings.LastWriteTimeUtc : default, settings.Exists ? settings.Length : -1,
                catalogue is { Exists: true } ? catalogue.LastWriteTimeUtc : default, catalogue is { Exists: true } ? catalogue.Length : -1,
                gameVersion?.Invoke());
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public async Task<GameExtensionsView> RefreshAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try { return await Task.Run(() => Publish(Service.ReadCards()), cancellationToken); }
        finally { gate.Release(); }
    }

    /// <summary>
    /// Serializes a narrow UI edit with other controller writes, merging it into the latest saved
    /// preference. External writers still use the store's revision check and cannot be overwritten.
    /// </summary>
    /// <param name="setting">
    /// <see cref="GameExtensionSetting.Enabled"/>, <see cref="GameExtensionSetting.ForceVersion"/>, or the key of one of the
    /// extension's own switches.
    /// </param>
    /// <exception cref="InvalidDataException">The extension is unknown, or has no such switch.</exception>
    public async Task<GameExtensionsView> ApplyEditAsync(string id, string setting, bool value,
        CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            // Read only after admission: queued edits must see all earlier committed edits.
            return await Task.Run(() => Publish(ApplyEdit(id, setting, value)), cancellationToken);
        }
        finally { gate.Release(); }
    }

    private IReadOnlyList<ExtensionCardView> ApplyEdit(string id, string setting, bool value)
    {
        var current = Service.ReadCards().SingleOrDefault(card => card.Definition.Id == id)
            ?? throw new InvalidDataException("Unknown extension.");
        if (setting == GameExtensionSetting.Enabled && value && !current.SupportsActivation)
            throw new InvalidDataException("Extension capability is unsupported.");
        var preference = current.Preference;
        preference = setting switch
        {
            GameExtensionSetting.Enabled => preference with { Enabled = value },
            GameExtensionSetting.ForceVersion => preference with { ForceVersion = value },
            // A switch belongs to the extension that declares it, not to any module sharing its capability.
            _ when ExtensionDescriptors.For(id).Option(setting) is not null => preference.WithOption(setting, value),
            _ => throw new InvalidDataException("This extension has no such option."),
        };
        // The card just read carries the revision the write is checked against; the cards after it come from what
        // was written.
        return Service.Save(current, preference);
    }

    public async Task RefreshRuntimeAsync(CancellationToken token)
    {
        if (!await gate.WaitAsync(0, token)) return;
        try
        {
            if (cachedCards is null)
            {
                // Runtime failures still belong in logs when this settings page was never opened. The modules are the
                // deployed catalogue's, as the cards and the game read them, not the list this build was made with.
                foreach (var definition in Catalogue())
                    if (definition.ActivationKind == ExtensionActivationKind.Continuous)
                        diagnostics?.Observe(definition.Id, extensionStatus?.Invoke(definition.Id));
                return;
            }
            // The controller is not the only settings writer: the runtime owner rolls back
            // definitively rejected requests with a revision-checked write. Never keep that
            // newer committed state hidden behind the UI's previous preference cache: any change to
            // the file is read again.
            var inputs = CardInputs();
            if (inputs is not null && inputs == cardInputs) { Publish(cachedCards!); return; }
            var cards = await Task.Run(Service.ReadCards, token);
            cardInputs = inputs;
            Publish(cards);
        }
        finally { gate.Release(); }
    }
    private GameExtensionsView Publish(IReadOnlyList<ExtensionCardView> cards)
    {
        cachedCards = cards;
        var statuses = new Dictionary<string, RuntimeExtensionStatus>(StringComparer.Ordinal);
        foreach (var card in cards)
        {
            if (card.Definition.ActivationKind != ExtensionActivationKind.Continuous) continue;
            var status = extensionStatus?.Invoke(card.Definition.Id);
            if (status is not null) statuses[card.Definition.Id] = status;
            diagnostics?.Observe(card.Definition.Id, status);
        }
        var view = new GameExtensionsView(cards, gameSavingEnabled?.Invoke() ?? true, lastSave?.Invoke(),
            statuses, runtimeWorldReady?.Invoke() ?? false);
        views.Publish(ViewKey, view, comparer: new ViewComparer());
        return view;
    }
    private sealed class ViewComparer : IEqualityComparer<GameExtensionsView>
    {
        public bool Equals(GameExtensionsView? x, GameExtensionsView? y) =>
            ReferenceEquals(x, y) || x is not null && y is not null && x.GameSavingEnabled == y.GameSavingEnabled
                && x.LastSave == y.LastSave && SameStatuses(x.Statuses, y.Statuses)
                && x.RuntimeWorldReady == y.RuntimeWorldReady && SameCards(x.Cards, y.Cards);
        public int GetHashCode(GameExtensionsView obj) => obj.Cards.Count;

        private static bool SameStatuses(IReadOnlyDictionary<string, RuntimeExtensionStatus>? left, IReadOnlyDictionary<string, RuntimeExtensionStatus>? right)
        {
            if ((left?.Count ?? 0) != (right?.Count ?? 0)) return false;
            if (left is null || right is null) return true;
            foreach (var (id, status) in left)
                if (!right.TryGetValue(id, out var other) || status != other) return false;
            return true;
        }

        private static bool SameCards(IReadOnlyList<ExtensionCardView> left, IReadOnlyList<ExtensionCardView> right)
        {
            if (left.Count != right.Count) return false;
            for (var i = 0; i < left.Count; i++)
            {
                var x = left[i]; var y = right[i];
                if (x.Preference != y.Preference || x.StatusCode != y.StatusCode || x.SettingsRevision != y.SettingsRevision
                    || x.VersionMatches != y.VersionMatches || x.GameVersion != y.GameVersion)
                    return false;
                var a = x.Definition; var b = y.Definition;
                // File catalogues are deliberately reread. Their freshly allocated capability lists
                // are metadata values, not identity changes that should recreate the settings cards.
                if (a.Id != b.Id || a.Version != b.Version || a.TitleKey != b.TitleKey
                    || a.DescriptionKey != b.DescriptionKey || a.ReadinessCode != b.ReadinessCode
                    || a.SupportedVersions != b.SupportedVersions
                    || !a.Capabilities.SequenceEqual(b.Capabilities, StringComparer.Ordinal))
                    return false;
            }
            return true;
        }
    }
}
