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

    /// <summary>
    /// Serializes a narrow UI edit with other controller writes, merging it into the latest saved
    /// preference. External writers still use the store's revision check and cannot be overwritten.
    /// </summary>
    public async Task<GameExtensionsView> ApplyEditAsync(string id, GameExtensionSetting setting, bool value,
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

    private IReadOnlyList<ExtensionCardView> ApplyEdit(string id, GameExtensionSetting setting, bool value)
    {
        if (!Enum.IsDefined(setting)) throw new ArgumentOutOfRangeException(nameof(setting));
        var current = service.ReadCards().SingleOrDefault(card => card.Definition.Id == id)
            ?? throw new InvalidDataException("Unknown extension.");
        if (setting == GameExtensionSetting.Enabled)
            return service.SetPreference(id, value, current.ForceVersion, current.SettingsRevision);
        if (setting == GameExtensionSetting.ForceVersion)
            return service.SetPreference(id, current.Enabled, value, current.SettingsRevision);

        // Vehicle preferences belong to this module, not to any module sharing its capability.
        if (id != ExtensionIds.VehicleDrivetrain || current.Definition.ActivationKind != ExtensionActivationKind.Continuous)
            throw new InvalidDataException("Vehicle options are unsupported for this extension.");
        var options = current.VehicleDrivetrain ?? new VehicleDrivetrainPreference();
        options = setting switch
        {
            GameExtensionSetting.Torque => options with { TorqueEnabled = value },
            GameExtensionSetting.Reverse => options with { ReverseEnabled = value },
            GameExtensionSetting.Steering => options with { SteeringEnabled = value },
            GameExtensionSetting.AreaLight => options with { AreaLightEnabled = value },
            _ => throw new ArgumentOutOfRangeException(nameof(setting))
        };
        return service.SetVehicleDrivetrainPreference(options, current.SettingsRevision);
    }

    /// <summary>One edit of the screen look's options, merged into the latest saved preference like any other edit.</summary>
    public async Task<GameExtensionsView> ApplyScreenLookAsync(Func<ScreenLookPreference, ScreenLookPreference> change,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(change);
        await gate.WaitAsync(cancellationToken);
        try
        {
            return await Task.Run(() =>
            {
                var current = service.ReadCards().SingleOrDefault(card => card.Definition.Id == ExtensionIds.ScreenLook)
                    ?? throw new InvalidDataException("Unknown extension.");
                return Publish(service.SetScreenLookPreference(change(current.ScreenLook ?? new ScreenLookPreference()), current.SettingsRevision));
            }, cancellationToken);
        }
        finally { gate.Release(); }
    }

    public async Task RefreshRuntimeAsync(CancellationToken token)
    {
        if (!await gate.WaitAsync(0, token)) return;
        try
        {
            if (cachedCards is null)
            {
                // Runtime failures still belong in logs when this settings page was never opened.
                foreach (var definition in ExtensionCatalog.BuiltIn)
                    if (definition.ActivationKind == ExtensionActivationKind.Continuous)
                        diagnostics?.Observe(definition.Id, extensionStatus?.Invoke(definition.Id));
                return;
            }
            // The controller is not the only settings writer: the runtime owner rolls back
            // definitively rejected requests with a revision-checked write. Never keep that
            // newer committed state hidden behind the UI's previous preference cache.
            Publish(await Task.Run(service.ReadCards, token));
        }
        finally { gate.Release(); }
    }
    public async Task<GameExtensionsView> SetVehicleDrivetrainPreferenceAsync(VehicleDrivetrainPreference preference,
        long expectedRevision, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try { return await Task.Run(() => Publish(service.SetVehicleDrivetrainPreference(preference, expectedRevision)), cancellationToken); }
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
                if (x.Enabled != y.Enabled || x.StatusCode != y.StatusCode || x.SettingsRevision != y.SettingsRevision
                    || x.ForceVersion != y.ForceVersion || x.VersionMatches != y.VersionMatches
                    || x.GameVersion != y.GameVersion || x.VehicleDrivetrain != y.VehicleDrivetrain || x.ScreenLook != y.ScreenLook)
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
