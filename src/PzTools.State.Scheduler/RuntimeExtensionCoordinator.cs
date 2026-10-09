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
        // Rounds in a row that lost the link; each waits longer before the next attempt (MaxLinkRetryDelay).
        int linkFailures = 0;

        bool StaleButUnchanged(RuntimeObservation latest, string? process, string? world)
        {
            if (latest.StreamEpoch != stream || latest.IsExtensionFresh) return false;
            staleSince ??= DateTimeOffset.UtcNow;
            return KeepsWorldWhileStale(latest, DateTimeOffset.UtcNow - staleSince.Value, process, world);
        }

        bool IsCurrent(string process, string world)
        {
            var latest = observations.Read();
            if (token.IsCancellationRequested || latest.StreamEpoch != stream) return false;
            if (!latest.IsExtensionFresh) return StaleButUnchanged(latest, process, world);
            staleSince = null;
            return latest.IsExtensionWorldReady && latest.Snapshot is { } current
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
                    bool ready = observation.StreamEpoch == stream && observation.IsExtensionWorldReady;
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
                                // The same settings a game the startup loader started runs with while the app is away
                                // (ResidentExtensionRequest): the module's own options over its tuning files.
                                actual = await module.Reconciliation!.ReconcileAsync(module.Session, process, world, revision,
                                    module.Id, preference.ForceVersion,
                                    () => ContinuousConfiguration.For(module.Id, bridgeDirectory, runtimeRoot, preference), token);
                                // What was sent for which revision: the evidence the game's acknowledgement is checked against.
                                if (module.Reconciliation.Sent is { } sent) module.Activation.RecordRequest(sent.Revision, sent.Configuration);
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
                                        ControlReady = false, AppliedConfiguration = null });
                                    break;
                                }
                                else published.Publish(module.Id, module.Activation.Observe(actual, revision));
                            }
                        }
                        handling = null;
                    }
                    linkFailures = 0;
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
                    // A lost or refused link is not the extension failing: the game was not asked anything, or could
                    // not answer. The preference stays and the link is tried again. Only what the game itself reports
                    // (a restart the update needs, here) or a failure while handling one module is definitive.
                    bool definitive = !shared || failed.State == RuntimeExtensionState.RestartRequired;
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
                        else if (definitive && process is not null && world is not null && revision >= 0 && IsCurrent(process, world))
                            await FailClosedAsync(module, failed, revision, process, world, stopped, leaseGone: shared);
                        else published.Publish(module.Id, failed);
                    }
                    linkFailures = definitive ? 0 : linkFailures + 1;
                    await Task.Delay(LinkRetryDelay(options.ReconcileIntervalMs, linkFailures), token);
                }
            }
        }
        finally
        {
            await CloseLeaseAsync(requestOff: false);
            published.Publish(new(RuntimeExtensionState.Disabled, "observer-disconnected"));
        }
    }

    /// <summary>The longest wait between attempts at a link that keeps failing: each attempt starts a helper process.</summary>
    internal static readonly TimeSpan MaxLinkRetryDelay = TimeSpan.FromSeconds(30);

    /// <summary>The reconcile interval, doubled for each failed link in a row up to <see cref="MaxLinkRetryDelay"/>.</summary>
    internal static TimeSpan LinkRetryDelay(int intervalMs, int failures) =>
        TimeSpan.FromMilliseconds(Math.Min(MaxLinkRetryDelay.TotalMilliseconds, intervalMs * Math.Pow(2, Math.Min(failures, 16))));

    /// <summary>How long a game whose state has stopped arriving keeps its extensions before they are released.</summary>
    internal static readonly TimeSpan TransientStaleGrace = TimeSpan.FromSeconds(30);

    /// <summary>
    /// Whether extensions bound to this process and world stay as they are while the game's state is not fresh: for
    /// <see cref="TransientStaleGrace"/> (a long save, a stall), and for as long as the game waits in its Lua debugger,
    /// which is the same world, frozen while its player reads the error.
    /// </summary>
    internal static bool KeepsWorldWhileStale(RuntimeObservation latest, TimeSpan staleFor, string? process, string? world) =>
        (latest.IsInDebugger || staleFor < TransientStaleGrace)
        && (latest.Snapshot is null || latest.Snapshot.ProcessSession == process && latest.Snapshot.WorldSession == world);

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
            or FormatException or OverflowException
        || error is OperationCanceledException && !token.IsCancellationRequested;
}
