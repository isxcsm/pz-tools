using PzTools.GameExtensions;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.GameBridge;

namespace PzTools.State.Scheduler;

/// <summary>
/// Uses the selected WATCH process/session, never discovers another game or owns another WATCH.
/// One control lease carries every continuous module. Each module is requested, applied, faulted
/// and turned off on its own: what happens to one does not change another's state or preference.
/// Only the loss of the lease itself concerns them all.
/// </summary>
internal sealed class RuntimeExtensionCoordinator(string bridgeDirectory, string runtimeRoot,
    RuntimeSnapshotStore observations, RuntimeExtensionStatusStore published, ExtensionControlOptions options)
{
    private sealed class Module(string id)
    {
        public string Id { get; } = id;
        public GameExtensionActivationState Activation { get; } = new();
        public GameExtensionModule? Session;
        public GameExtensionReconciler? Reconciliation;
        public long DisabledRevision = -1;
        public (string Process, string World, long Revision)? OffUnconfirmed;
        /// <summary>The lease this module's evidence came from is gone, or the module was turned off on it.</summary>
        public void Forget() { Session = null; Reconciliation = null; DisabledRevision = -1; }
    }

    public async Task RunAsync(int processId, string stream, CancellationToken token)
    {
        var settings = new ExtensionSettingsStore(runtimeRoot);
        var modules = ContinuousModules().Select(id => new Module(id)).ToArray();
        GameExtensionClient? client = null;
        // Since when the game's state has not been fresh. A game thread that is busy for a moment
        // (a long save, a stall) makes its samples old; that is not the world going away.
        DateTimeOffset? staleSince = null;
        string? boundProcess = null, boundWorld = null;

        bool StaleButUnchanged(RuntimeObservation latest, string? process, string? world)
        {
            if (latest.StreamEpoch != stream || latest.IsFresh) return false;
            staleSince ??= DateTimeOffset.UtcNow;
            return DateTimeOffset.UtcNow - staleSince < TransientStaleGrace
                && (latest.Snapshot is null || latest.Snapshot.ProcessSession == process && latest.Snapshot.WorldSession == world);
        }

        bool IsCurrent(string process, string world)
        {
            var latest = observations.Read();
            if (token.IsCancellationRequested || latest.StreamEpoch != stream) return false;
            if (!latest.IsFresh) return StaleButUnchanged(latest, process, world);
            staleSince = null;
            return latest.Snapshot is { IsWorldReady: true } current
                && current.ProcessSession == process && current.WorldSession == world;
        }

        // Dropping the lease revokes every module in the game; asking for OFF first also retires them cleanly.
        async Task<RuntimeExtensionStatus?> CloseLeaseAsync(bool requestOff)
        {
            var lease = client;
            client = null;
            foreach (var module in modules) { module.Forget(); module.Activation.Disconnect(); }
            RuntimeExtensionStatus? result = null;
            if (lease is not null)
            {
                try { if (requestOff && !token.IsCancellationRequested) result = await lease.DisableAsync(token); }
                catch (Exception failure) when (Recoverable(failure, token)) { /* EOF/lease expiry still revokes admission. */ }
                finally { await lease.DisposeAsync(); }
            }
            return result;
        }

        // One module is turned off in the game and in the saved preferences. The lease and the other modules stay.
        async Task FailClosedAsync(Module module, RuntimeExtensionStatus failure, long revision, string process, string world,
            RuntimeExtensionStatus? stopped = null, bool leaseGone = false)
        {
            if (!leaseGone && module.Session is { } session)
            {
                try { if (!token.IsCancellationRequested) stopped = await session.DisableAsync(token); }
                // An OFF that gets no answer is not an OFF. Dropping the lease is: it revokes everything.
                catch (Exception error) when (Recoverable(error, token)) { stopped = await CloseLeaseAsync(requestOff: false); }
            }
            module.Forget();
            // Cleanup failure is not a successful OFF. Preserve restart-required evidence.
            if (stopped?.State == RuntimeExtensionState.RestartRequired) failure = stopped;
            if (!module.Activation.FailClosed(failure, revision, () => IsCurrent(process, world), expected =>
                {
                    try { return settings.SetEnabled(module.Id, false, expected).Revision; }
                    catch (ExtensionSettingsConflictException) { return null; }
                    catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException)
                    { return null; } // Keep this revision locked OFF even if the preferences file cannot be written.
                })) return;
            published.Publish(module.Id, module.Activation.Failure!);
        }

        try
        {
            while (!token.IsCancellationRequested)
            {
                long revision = -1;
                string? process = null, world = null;
                // Unknown preferences are reported like a requested extension.
                var wanted = modules.ToDictionary(module => module.Id, _ => true, StringComparer.Ordinal);
                Module? handling = null;
                try
                {
                    var configuration = settings.Read();
                    revision = configuration.Revision;
                    var preferences = modules.ToDictionary(module => module.Id,
                        module => configuration.Extensions.GetValueOrDefault(module.Id) ?? new(), StringComparer.Ordinal);
                    foreach (var module in modules) wanted[module.Id] = preferences[module.Id].Enabled;
                    var observation = observations.Read();
                    var snapshot = observation.Snapshot;
                    bool ready = observation.StreamEpoch == stream && observation.IsFresh && snapshot?.IsWorldReady == true;
                    if (ready) staleSince = null;
                    if (!ready && client is not null && modules.Any(module => module.Session is not null)
                        && StaleButUnchanged(observation, boundProcess, boundWorld))
                    {
                        // Keep the lease and every module as they are; only renew the lease. Tearing them down
                        // here would make the game reinstall each module after every long save.
                        foreach (var module in modules)
                            if (module.Session is { } session) await session.PingAsync(token);
                    }
                    else if (!ready)
                    {
                        await CloseLeaseAsync(requestOff: true);
                        foreach (var module in modules)
                            published.Publish(module.Id, new(wanted[module.Id] ? RuntimeExtensionState.Pending : RuntimeExtensionState.Disabled,
                                "waiting-for-local-world", RequestedRevision: revision));
                    }
                    else
                    {
                        process = snapshot!.ProcessSession; world = snapshot.WorldSession!;
                        boundProcess = process; boundWorld = world;
                        bool rebound = false;
                        foreach (var module in modules) rebound |= module.Activation.Bind(process, world);
                        if (rebound) await CloseLeaseAsync(requestOff: true);

                        foreach (var module in modules)
                        {
                            handling = module;
                            var preference = preferences[module.Id];
                            if (module.Activation.Blocked(revision) is { } blocked) { published.Publish(module.Id, blocked); continue; }
                            if (!preference.Enabled && module.OffUnconfirmed == (process, world, revision)) continue;
                            RuntimeExtensionStatus? actual = null;
                            if (module.Session is null)
                            {
                                if (client is null)
                                {
                                    published.Publish(module.Id, new(RuntimeExtensionState.Pending, "connecting", process, world,
                                        RequestedRevision: revision));
                                    client = await GameExtensionClient.ConnectAsync(bridgeDirectory, processId,
                                        TimeSpan.FromSeconds(options.ConnectTimeoutSeconds), token);
                                }
                                module.Session = client.Module(module.Id);
                                actual = await module.Session.StatusAsync(token);
                                module.Activation.VerifyTarget(actual, revision);
                                module.Reconciliation = new(actual);
                            }
                            if (!IsCurrent(process, world)) { await CloseLeaseAsync(requestOff: true); break; }
                            // STATUS can expose a poisoned host from an earlier controller/world. Do not
                            // attempt APPLY or report readiness before handling that process-wide failure.
                            if (actual is not null && GameExtensionActivationState.IsDefinitiveFailure(actual, false))
                            {
                                await FailClosedAsync(module, actual, revision, process, world);
                                continue;
                            }

                            if (!preference.Enabled)
                            {
                                // Confirm remote retirement; merely saving Enabled=false is not applied OFF evidence.
                                actual = module.DisabledRevision != revision || actual?.State is RuntimeExtensionState.Active or RuntimeExtensionState.Pending
                                    ? await module.Session.DisableAsync(token) : actual ?? await module.Session.PingAsync(token);
                                if (!IsCurrent(process, world)) { await CloseLeaseAsync(requestOff: true); break; }
                                module.Activation.VerifyTarget(actual, revision);
                                if (GameExtensionActivationState.IsDefinitiveFailure(actual, false))
                                    await FailClosedAsync(module, actual, revision, process, world, stopped: actual);
                                else if (actual.State != RuntimeExtensionState.Disabled)
                                    throw new InvalidDataException("The extension did not acknowledge OFF.");
                                else
                                {
                                    module.DisabledRevision = revision;
                                    module.Reconciliation = new(actual);
                                    published.Publish(module.Id, module.Activation.Observe(actual, revision));
                                }
                            }
                            else
                            {
                                module.DisabledRevision = -1;
                                long requestRevision = revision;
                                actual = await module.Reconciliation!.ReconcileAsync(module.Session, process, world, revision,
                                    module.Id, preference.ForceVersion, () => Configure(module, preference, requestRevision), token);
                                if (!IsCurrent(process, world)) { await CloseLeaseAsync(requestOff: true); break; }
                                module.Activation.VerifyTarget(actual, revision);
                                if (GameExtensionActivationState.IsDefinitiveFailure(actual, module.Reconciliation.RequestRejected))
                                    await FailClosedAsync(module, actual, revision, process, world);
                                else if (actual.State == RuntimeExtensionState.Disabled)
                                {
                                    // A revoked lease is not an applied request; reconnect without manufacturing success.
                                    // The game revokes for reasons that concern every module (the world changed, its
                                    // state became unreadable), so the lease is renewed as a whole.
                                    await CloseLeaseAsync(requestOff: true);
                                    published.Publish(module.Id, actual with { WorldSession = world, RequestedRevision = revision,
                                        ControlReady = false, AppliedVehicleOptions = null });
                                    break;
                                }
                                else published.Publish(module.Id, module.Activation.Observe(actual, revision));
                            }
                        }
                        handling = null;
                    }
                    await Task.Delay(options.ReconcileIntervalMs, token);
                }
                catch (ExtensionSessionMismatchException)
                {
                    await CloseLeaseAsync(requestOff: true);
                    foreach (var module in modules)
                        published.Publish(module.Id, new(RuntimeExtensionState.Pending, "control-session-changed",
                            process ?? "", world, RequestedRevision: revision));
                    await Task.Delay(options.ReconcileIntervalMs, token);
                }
                catch (Exception error) when (Recoverable(error, token))
                {
                    // A broken or unanswered lease concerns every module. Anything else happened while
                    // handling one module and stays with it.
                    bool shared = handling is null || ConcernsTheLease(error);
                    // A game still running the bootstrap from before an update of the app refuses the link until it
                    // restarts. That is the update's restart, as the state stream reports it, not a failed extension:
                    // the preference stays on and the extension comes back with the next game.
                    var failed = error is GameSaveException { Code: "restart-required" }
                        ? new RuntimeExtensionStatus(RuntimeExtensionState.RestartRequired,
                            GameExtensionActivationState.BootstrapUpdateReason, process ?? "", world, RequestedRevision: revision)
                        : new RuntimeExtensionStatus(RuntimeExtensionState.FaultedPassThrough,
                            error is GameSaveException ? "connection-unavailable" : "configuration-or-connection-failed",
                            process ?? "", world, RequestedRevision: revision);
                    var affected = shared ? modules : [handling!];
                    RuntimeExtensionStatus? stopped = null;
                    if (shared) stopped = await CloseLeaseAsync(requestOff: affected.Any(module => wanted[module.Id]));
                    foreach (var module in affected)
                    {
                        if (!wanted[module.Id])
                        {
                            // The user has this extension off. Failing to confirm that with the game is not
                            // their problem to act on: report Disabled and do not attach again for this world.
                            if (process is not null && world is not null) module.OffUnconfirmed = (process, world, revision);
                            published.Publish(module.Id, new(RuntimeExtensionState.Disabled, "control-offline", process ?? "", world,
                                RequestedRevision: revision));
                        }
                        else if (process is not null && world is not null && revision >= 0 && IsCurrent(process, world))
                            await FailClosedAsync(module, failed, revision, process, world, stopped, leaseGone: shared);
                        else published.Publish(module.Id, failed);
                    }
                    await Task.Delay(options.ReconcileIntervalMs, token);
                }
            }
        }
        finally
        {
            await CloseLeaseAsync(requestOff: false);
            published.Publish(new(RuntimeExtensionState.Disabled, "observer-disconnected"));
        }
    }

    /// <summary>How long a game whose state has stopped arriving keeps its extensions before they are released.</summary>
    internal static readonly TimeSpan TransientStaleGrace = TimeSpan.FromSeconds(30);

    /// <summary>What a module is asked to do, from its own saved options and its own tuning file.</summary>
    private IReadOnlyDictionary<string, string> Configure(Module module, ExtensionPreference preference, long revision)
    {
        switch (module.Id)
        {
            case ExtensionIds.VehicleDrivetrain:
                var tuning = VehicleDrivetrainConfiguration.Load(bridgeDirectory, runtimeRoot, preference.VehicleDrivetrain);
                bool enabled = tuning["probe_only"] != "true";
                module.Activation.RecordRequest(revision, new(enabled && tuning["torque_enabled"] == "true",
                    enabled && tuning["reverse_enabled"] == "true", enabled && tuning["steering_enabled"] == "true",
                    enabled && tuning["area_light_enabled"] == "true"));
                return tuning;
            default:
                throw new InvalidDataException("No configuration is defined for this continuous module.");
        }
    }

    /// <summary>The modules the deployed catalogue runs continuously; the built-in list when that file cannot be read.</summary>
    private IReadOnlyList<string> ContinuousModules()
    {
        IReadOnlyList<ExtensionDefinition> catalogue;
        try { catalogue = ExtensionCatalog.ReadFile(Path.Combine(bridgeDirectory, "extensions", "catalog.tsv")); }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException) { catalogue = ExtensionCatalog.BuiltIn; }
        return catalogue.Where(definition => definition.ActivationKind == ExtensionActivationKind.Continuous)
            .Select(definition => definition.Id).ToArray();
    }

    private static bool ConcernsTheLease(Exception error) =>
        error is IOException or GameSaveException or ObjectDisposedException or OperationCanceledException
            or System.ComponentModel.Win32Exception;

    private static bool Recoverable(Exception error, CancellationToken token) =>
        error is IOException or InvalidDataException or UnauthorizedAccessException or GameSaveException
            or InvalidOperationException or System.ComponentModel.Win32Exception or ArgumentException
            or FormatException or OverflowException or Tomlyn.TomlException
        || error is OperationCanceledException && !token.IsCancellationRequested;
}
