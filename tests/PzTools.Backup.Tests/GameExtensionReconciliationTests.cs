using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.GameBridge;

namespace PzTools.Backup.Tests;

public sealed class GameExtensionReconciliationTests
{
    private static readonly string ProcessId = new('a', 32), WorldId = new('b', 32), GenerationId = new('c', 32);
    private static RuntimeExtensionStatus Active(long revision, string? reason = null) => new(RuntimeExtensionState.Active,
        reason, ProcessId, WorldId, GenerationId, revision, "0.1.0", new string('d', 64));
    private static RuntimeExtensionStatus Pending(long applied) => Active(applied) with { State = RuntimeExtensionState.Pending, Reason = "safe-boundary" };
    private static readonly IReadOnlyDictionary<string, string> Configuration = new Dictionary<string, string>();

    [Fact]
    public async Task AcceptedRequestWaitsForAppliedRevisionWithoutResending()
    {
        var session = new Session(); session.Applies.Enqueue(Pending(-1)); session.Pings.Enqueue(Pending(-1)); session.Pings.Enqueue(Active(1));
        var reconcile = new GameExtensionReconciler(new(RuntimeExtensionState.Disabled));
        Assert.Equal(RuntimeExtensionState.Pending, (await Step(reconcile, session, 1)).State);
        Assert.Equal(-1, (await Step(reconcile, session, 1)).AppliedRevision);
        Assert.Equal(1, (await Step(reconcile, session, 1)).AppliedRevision);
        Assert.Single(session.ExpectedRevisions);
    }

    [Fact]
    public async Task NewerRevisionSupersedesPendingWithoutFailureOrDuplicateResends()
    {
        var session = new Session();
        session.Applies.Enqueue(Pending(1)); session.Applies.Enqueue(Pending(1));
        session.Pings.Enqueue(Pending(1)); session.Pings.Enqueue(Active(3));
        var reconcile = new GameExtensionReconciler(Active(1));
        Assert.Equal(RuntimeExtensionState.Pending, (await Step(reconcile, session, 2)).State);
        Assert.False(reconcile.RequestRejected);
        Assert.Equal(RuntimeExtensionState.Pending, (await Step(reconcile, session, 3)).State);
        Assert.False(reconcile.RequestRejected);
        Assert.Equal(1, (await Step(reconcile, session, 3)).AppliedRevision);
        Assert.Equal(3, (await Step(reconcile, session, 3)).AppliedRevision);
        Assert.False(reconcile.RequestRejected);
        Assert.Equal(new long[] { 1, 1 }, session.ExpectedRevisions);
        Assert.Equal(new long[] { 2, 3 }, session.RequestedRevisions);
    }

    [Fact]
    public async Task RejectionReasonSurvivesHeartbeatsButNewRevisionRetries()
    {
        var session = new Session(); session.Applies.Enqueue(Active(1, "update-rejected:IllegalArgumentException"));
        session.Pings.Enqueue(Active(1)); session.Applies.Enqueue(Pending(1));
        var reconcile = new GameExtensionReconciler(Active(1));
        var rejected = await Step(reconcile, session, 2);
        Assert.Equal(1, rejected.AppliedRevision); Assert.Equal(RuntimeExtensionState.Active, rejected.State);
        Assert.Equal(rejected.Reason, (await Step(reconcile, session, 2)).Reason);
        Assert.Single(session.ExpectedRevisions);
        Assert.Equal(RuntimeExtensionState.Pending, (await Step(reconcile, session, 3)).State);
        Assert.Equal(2, session.ExpectedRevisions.Count);
    }

    [Fact]
    public async Task InvalidConfigurationIsEvaluatedOncePerRevision()
    {
        var session = new Session(); session.Pings.Enqueue(Active(1)); session.Pings.Enqueue(Active(1)); session.Applies.Enqueue(Pending(1));
        var reconcile = new GameExtensionReconciler(Active(1)); int reads = 0;
        IReadOnlyDictionary<string, string> Invalid() { reads++; throw new InvalidDataException("Invalid TOML"); }
        Assert.Equal("configuration-rejected", (await Step(reconcile, session, 2, Invalid)).Reason);
        Assert.Equal("configuration-rejected", (await Step(reconcile, session, 2, Invalid)).Reason);
        Assert.Equal(1, reads); Assert.Empty(session.ExpectedRevisions);
        Assert.Equal(RuntimeExtensionState.Pending, (await Step(reconcile, session, 3)).State);
        Assert.Single(session.ExpectedRevisions);
    }

    [Fact]
    public async Task ConflictRefreshesActualRevisionAndRetriesOnce()
    {
        var session = new Session(); session.Applies.Enqueue(Active(2, "revision-conflict")); session.Statuses.Enqueue(Active(2)); session.Applies.Enqueue(Pending(2));
        var reconcile = new GameExtensionReconciler(Active(1));
        Assert.Equal(RuntimeExtensionState.Pending, (await Step(reconcile, session, 3)).State);
        Assert.Equal(new long[] { 1, 2 }, session.ExpectedRevisions); Assert.Equal(1, session.StatusCalls);
    }

    [Fact]
    public async Task ConflictAlreadyAppliedIsNotSentAgainAndPersistentConflictDoesNotSpin()
    {
        var already = new Session(); already.Applies.Enqueue(Active(2, "revision-conflict")); already.Statuses.Enqueue(Active(2));
        Assert.Equal(2, (await Step(new(Active(1)), already, 2)).AppliedRevision); Assert.Single(already.ExpectedRevisions);
        var conflict = new Session(); conflict.Applies.Enqueue(Active(3, "revision-conflict")); conflict.Statuses.Enqueue(Active(3));
        conflict.Applies.Enqueue(Active(3, "revision-conflict")); conflict.Pings.Enqueue(Active(3));
        var reconcile = new GameExtensionReconciler(Active(1));
        Assert.Equal("revision-conflict", (await Step(reconcile, conflict, 2)).Reason);
        Assert.Equal("revision-conflict", (await Step(reconcile, conflict, 2)).Reason);
        Assert.Equal(2, conflict.ExpectedRevisions.Count);
    }

    [Fact]
    public async Task WrongWorldStatusCannotBePublishedAsActive()
    {
        var session = new Session(); session.Applies.Enqueue(Active(1) with { WorldSession = new string('e', 32) });
        await Assert.ThrowsAsync<ExtensionSessionMismatchException>(() => Step(new(new(RuntimeExtensionState.Disabled)), session, 1));
    }

    [Fact]
    public async Task CallbackFaultTakesPrecedenceOverOldRejectedUpdateReason()
    {
        var session = new Session(); session.Applies.Enqueue(Active(1, "configuration-rejected"));
        session.Pings.Enqueue(Active(1, "vehicle-callback-failed") with { State = RuntimeExtensionState.FaultedPassThrough });
        var reconcile = new GameExtensionReconciler(Active(1)); await Step(reconcile, session, 2);
        var result = await Step(reconcile, session, 2);
        Assert.Equal(RuntimeExtensionState.FaultedPassThrough, result.State); Assert.Equal("vehicle-callback-failed", result.Reason);
    }

    [Fact]
    public async Task SocketDisposalRevokesBeforeWaitingForReadAndIsIdempotent()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
        using var transport = new TcpClient(); var accept = listener.AcceptTcpClientAsync();
        await transport.ConnectAsync((IPEndPoint)listener.LocalEndpoint); using var remote = await accept;
        await using var session = Create(transport); using var reader = new StreamReader(remote.GetStream(), Encoding.UTF8);
        var status = session.StatusAsync(CancellationToken.None);
        Assert.StartsWith("STATUS\t", await reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(5)));
        var dispose = session.DisposeAsync().AsTask();
        Assert.Null(await reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(5)));
        await Assert.ThrowsAnyAsync<Exception>(() => status);
        await dispose.WaitAsync(TimeSpan.FromSeconds(5)); await session.DisposeAsync();
        await Assert.ThrowsAsync<ObjectDisposedException>(() => session.PingAsync(CancellationToken.None));
    }

    [Fact]
    public async Task CancelledPartialResponseCannotBeReusedForNextCommand()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
        using var transport = new TcpClient(); var accept = listener.AcceptTcpClientAsync();
        await transport.ConnectAsync((IPEndPoint)listener.LocalEndpoint); using var remote = await accept;
        await using var session = Create(transport); using var reader = new StreamReader(remote.GetStream(), Encoding.UTF8);
        using var cancel = new CancellationTokenSource(); var status = session.StatusAsync(cancel.Token);
        Assert.StartsWith("STATUS\t", await reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(5)));
        await remote.GetStream().WriteAsync("STATE\tpartial"u8.ToArray()); await cancel.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => status);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => session.StatusAsync(CancellationToken.None));
        await session.DisposeAsync();
    }

    private static GameExtensionClient Create(TcpClient socket) =>
        (GameExtensionClient)typeof(GameExtensionClient).GetConstructor(BindingFlags.Instance | BindingFlags.NonPublic,
            null, [typeof(TcpClient)], null)!.Invoke([socket]);

    private static Task<RuntimeExtensionStatus> Step(GameExtensionReconciler value, Session session, long revision,
        Func<IReadOnlyDictionary<string, string>>? config = null) => value.ReconcileAsync(session, ProcessId, WorldId,
            revision, "pztools.vehicle-drivetrain", false, config ?? (() => Configuration), CancellationToken.None);

    private sealed class Session : IGameExtensionSession
    {
        public Queue<RuntimeExtensionStatus> Applies { get; } = new();
        public Queue<RuntimeExtensionStatus> Pings { get; } = new();
        public Queue<RuntimeExtensionStatus> Statuses { get; } = new();
        public List<long> ExpectedRevisions { get; } = new();
        public List<long> RequestedRevisions { get; } = new();
        public int StatusCalls { get; private set; }
        public Task<RuntimeExtensionStatus> StatusAsync(CancellationToken token) { StatusCalls++; return Task.FromResult(Statuses.Dequeue()); }
        public Task<RuntimeExtensionStatus> PingAsync(CancellationToken token) => Task.FromResult(Pings.Dequeue());
        public Task<RuntimeExtensionStatus> ApplyAsync(string processSession, string worldSession, long expectedRevision,
            long revision, string moduleId, bool forceVersion, IReadOnlyDictionary<string, string> configuration, CancellationToken token)
        { ExpectedRevisions.Add(expectedRevision); RequestedRevisions.Add(revision); return Task.FromResult(Applies.Dequeue()); }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
