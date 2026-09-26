using PzTools.GameExtensions;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.SaveBridge;

namespace PzTools.State.Scheduler;

/// <summary>Uses the selected WATCH process/session, never discovers another game or owns another WATCH.</summary>
internal sealed class RuntimeExtensionCoordinator(string bridgeDirectory, string runtimeRoot,
    RuntimeSnapshotStore observations, RuntimeExtensionStatusStore published)
{
    public async Task RunAsync(int processId, string stream, CancellationToken token)
    {
        var settings = new ExtensionSettingsStore(runtimeRoot);
        var activation = new GameExtensionActivationState();
        GameExtensionClient? client = null;
        GameExtensionReconciler? reconciliation = null;
        long disabledRevision = -1;

        bool IsCurrent(string process, string world)
        {
            var latest = observations.Read();
            return !token.IsCancellationRequested && latest.StreamEpoch == stream && latest.IsFresh
                && latest.Snapshot is { IsWorldReady: true } current
                && current.ProcessSession == process && current.WorldSession == world;
        }

        async Task<RuntimeExtensionStatus?> CloseLeaseAsync(bool requestOff)
        {
            var lease = client;
            client = null; reconciliation = null; disabledRevision = -1;
            RuntimeExtensionStatus? result = null;
            if (lease is not null)
            {
                try { if (requestOff && !token.IsCancellationRequested) result = await lease.DisableAsync(token); }
                catch (Exception failure) when (Recoverable(failure, token)) { /* EOF/lease expiry still revokes admission. */ }
                finally { await lease.DisposeAsync(); }
            }
            activation.Disconnect();
            return result;
        }

        async Task FailClosedAsync(RuntimeExtensionStatus failure, long revision, string process, string world)
        {
            var stopped = await CloseLeaseAsync(requestOff: true);
            // Cleanup failure is not a successful OFF. Preserve restart-required evidence.
            if (stopped?.State == RuntimeExtensionState.RestartRequired) failure = stopped;
            if (!activation.FailClosed(failure, revision, () => IsCurrent(process, world), expected =>
                {
                    try { return settings.SetEnabled(ExtensionIds.VehicleDrivetrain, false, expected).Revision; }
                    catch (ExtensionSettingsConflictException) { return null; }
                    catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException)
                    { return null; } // Keep this revision locked OFF even if the preferences file cannot be written.
                })) return;
            published.Publish(activation.Failure!);
        }
        try
        {
            while (!token.IsCancellationRequested)
            {
                long revision = -1;
                string? process = null, world = null;
                try
                {
                    var configuration = settings.Read();
                    revision = configuration.Revision;
                    var preference = configuration.Extensions.GetValueOrDefault(ExtensionIds.VehicleDrivetrain) ?? new();
                    var observation = observations.Read();
                    var snapshot = observation.Snapshot;
                    bool ready = observation.StreamEpoch == stream && observation.IsFresh && snapshot?.IsWorldReady == true;
                    if (!ready)
                    {
                        await CloseLeaseAsync(requestOff: true);
                        published.Publish(new(preference.Enabled ? RuntimeExtensionState.Pending : RuntimeExtensionState.Disabled,
                            "waiting-for-local-world", RequestedRevision: revision));
                    }
                    else
                    {
                        process = snapshot!.ProcessSession; world = snapshot.WorldSession!;
                        if (activation.Bind(process, world)) await CloseLeaseAsync(requestOff: true);
                        if (activation.Blocked(revision) is { } blocked)
                        {
                            published.Publish(blocked);
                            await Task.Delay(1000, token);
                            continue;
                        }
                        RuntimeExtensionStatus? actual = null;
                        if (client is null)
                        {
                            published.Publish(new(RuntimeExtensionState.Pending, "connecting", process, world,
                                RequestedRevision: revision));
                            client = await GameExtensionClient.ConnectAsync(bridgeDirectory, processId, token);
                            actual = await client.StatusAsync(token);
                            activation.VerifyTarget(actual, revision);
                            reconciliation = new(actual);
                        }
                        if (!IsCurrent(process, world)) { await CloseLeaseAsync(requestOff: true); continue; }
                        // STATUS can expose a poisoned host from an earlier controller/world. Do not
                        // attempt APPLY or report readiness before handling that process-wide failure.
                        if (actual is not null && GameExtensionActivationState.IsDefinitiveFailure(actual, false))
                        {
                            await FailClosedAsync(actual, revision, process, world);
                            await Task.Delay(1000, token);
                            continue;
                        }

                        if (!preference.Enabled)
                        {
                            // Confirm remote retirement; merely saving Enabled=false is not applied OFF evidence.
                            actual = disabledRevision != revision || actual?.State is RuntimeExtensionState.Active or RuntimeExtensionState.Pending
                                ? await client.DisableAsync(token) : actual ?? await client.PingAsync(token);
                            if (!IsCurrent(process, world)) { await CloseLeaseAsync(requestOff: true); continue; }
                            activation.VerifyTarget(actual, revision);
                            if (GameExtensionActivationState.IsDefinitiveFailure(actual, false))
                                await FailClosedAsync(actual, revision, process, world);
                            else if (actual.State != RuntimeExtensionState.Disabled)
                                throw new InvalidDataException("The extension did not acknowledge OFF.");
                            else
                            {
                                disabledRevision = revision;
                                reconciliation = new(actual);
                                published.Publish(activation.Observe(actual, revision));
                            }
                        }
                        else
                        {
                            disabledRevision = -1;
                            actual = await reconciliation!.ReconcileAsync(client, process, world, revision,
                                ExtensionIds.VehicleDrivetrain, preference.ForceVersion, () =>
                                {
                                    var tuning = VehicleDrivetrainConfiguration.Load(bridgeDirectory, runtimeRoot, preference.VehicleDrivetrain);
                                    bool enabled = tuning["probe_only"] != "true";
                                    activation.RecordRequest(revision, new(enabled && tuning["torque_enabled"] == "true",
                                        enabled && tuning["reverse_enabled"] == "true", enabled && tuning["steering_enabled"] == "true"));
                                    return tuning;
                                }, token);
                            if (!IsCurrent(process, world)) { await CloseLeaseAsync(requestOff: true); continue; }
                            activation.VerifyTarget(actual, revision);
                            if (GameExtensionActivationState.IsDefinitiveFailure(actual, reconciliation.RequestRejected))
                                await FailClosedAsync(actual, revision, process, world);
                            else if (actual.State == RuntimeExtensionState.Disabled)
                            {
                                // A revoked lease is not an applied request; reconnect without manufacturing success.
                                await CloseLeaseAsync(requestOff: true);
                                published.Publish(actual with { WorldSession = world, RequestedRevision = revision,
                                    ControlReady = false, AppliedVehicleOptions = null });
                            }
                            else published.Publish(activation.Observe(actual, revision));
                        }
                    }
                    await Task.Delay(1000, token);
                }
                catch (ExtensionSessionMismatchException)
                {
                    await CloseLeaseAsync(requestOff: true);
                    published.Publish(new(RuntimeExtensionState.Pending, "control-session-changed",
                        process ?? "", world, RequestedRevision: revision));
                    await Task.Delay(1000, token);
                }
                catch (Exception error) when (Recoverable(error, token))
                {
                    var failed = new RuntimeExtensionStatus(error is GameSaveException { Code: "restart-required" }
                            ? RuntimeExtensionState.RestartRequired : RuntimeExtensionState.FaultedPassThrough,
                        error is GameSaveException ? "connection-unavailable" : "configuration-or-connection-failed",
                        process ?? "", world, RequestedRevision: revision);
                    if (process is not null && world is not null && revision >= 0 && IsCurrent(process, world))
                        await FailClosedAsync(failed, revision, process, world);
                    else
                    {
                        await CloseLeaseAsync(requestOff: true);
                        published.Publish(failed);
                    }
                    await Task.Delay(1000, token);
                }
            }
        }
        finally
        {
            await CloseLeaseAsync(requestOff: false);
            published.Publish(new(RuntimeExtensionState.Disabled, "observer-disconnected"));
        }
    }

    private static bool Recoverable(Exception error, CancellationToken token) =>
        error is IOException or InvalidDataException or UnauthorizedAccessException or GameSaveException
            or InvalidOperationException or System.ComponentModel.Win32Exception or ArgumentException
            or FormatException or OverflowException or Tomlyn.TomlException
        || error is OperationCanceledException && !token.IsCancellationRequested;
}
