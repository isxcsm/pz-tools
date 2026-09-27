using System.Data;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using Microsoft.Data.Sqlite;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Tests;

public sealed class RepositoryConnectionInitializationTests
{
    [Fact]
    public async Task TransientMappedFileError_ClosesEveryFailedHandleBeforeRetry()
    {
        using var temp = new TempDirectory();
        var connections = new List<SqliteConnection>();
        var calls = 0;
        var fault = new SqliteException("mapped startup file", 10, 1546);
        var result = await RepositoryConnectionInitialization.OpenAsync<int>(() =>
        {
            Assert.All(connections, item => Assert.Equal(ConnectionState.Closed, item.State));
            var connection = new SqliteConnection($"Data Source={temp.GetPath("test.db")};Pooling=False");
            connections.Add(connection);
            return connection;
        }, (connection, token) =>
        {
            calls++;
            if (calls <= 2) { SetLastError(1224); throw fault; }
            return Task.FromResult(42);
        }, default);
        await using var returned = result.Connection;
        Assert.Equal(3, calls);
        Assert.Equal(42, result.Value);
        Assert.Equal(ConnectionState.Open, returned.State);
    }

    [Theory]
    [InlineData(10, 1546, 5)]
    [InlineData(10, 778, 1224)]
    [InlineData(11, 11, 1224)]
    [InlineData(5, 5, 1224)]
    public async Task OtherErrors_AreNotRetried(int primary, int extended, uint osError)
    {
        using var temp = new TempDirectory();
        var connections = new List<SqliteConnection>();
        var expected = new SqliteException("not retryable", primary, extended);
        var actual = await Assert.ThrowsAsync<SqliteException>(() =>
            RepositoryConnectionInitialization.OpenAsync<int>(() =>
            {
                var connection = new SqliteConnection($"Data Source={temp.GetPath("test.db")};Pooling=False");
                connections.Add(connection);
                return connection;
            }, (connection, token) => { SetLastError(osError); throw expected; }, default));
        Assert.Same(expected, actual);
        Assert.Equal(ConnectionState.Closed, Assert.Single(connections).State);
    }

    [Fact]
    public async Task PersistentMappedFileError_IsBoundedAndPreservesFailure()
    {
        using var temp = new TempDirectory();
        var connections = new List<SqliteConnection>();
        var expected = new SqliteException("persistent mapped file", 10, 1546);
        var actual = await Assert.ThrowsAsync<SqliteException>(() =>
            RepositoryConnectionInitialization.OpenAsync<int>(() =>
            {
                var connection = new SqliteConnection($"Data Source={temp.GetPath("test.db")};Pooling=False");
                connections.Add(connection);
                return connection;
            }, (connection, token) => { SetLastError(1224); throw expected; }, default));
        Assert.Same(expected, actual);
        Assert.Equal(RepositoryConnectionInitialization.MaximumAttempts, connections.Count);
        Assert.All(connections, item => Assert.Equal(ConnectionState.Closed, item.State));
    }

    [Fact]
    public async Task CancelledBackoff_DoesNotOpenAnotherHandle()
    {
        using var temp = new TempDirectory();
        using var cancellation = new CancellationTokenSource();
        var connections = new List<SqliteConnection>();
        var expected = new SqliteException("mapped startup file", 10, 1546);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            RepositoryConnectionInitialization.OpenAsync<int>(() =>
            {
                var connection = new SqliteConnection($"Data Source={temp.GetPath("test.db")};Pooling=False");
                connections.Add(connection);
                return connection;
            }, (connection, token) =>
            {
                cancellation.Cancel();
                SetLastError(1224);
                throw expected;
            }, cancellation.Token));
        Assert.Equal(ConnectionState.Closed, Assert.Single(connections).State);
    }

    [Fact]
    public async Task RealMappedWalIndex_ReleasesThenOpensWithoutChangingRepository()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var identity = repository.Identity;
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var stream = new FileStream(repository.DatabasePath + "-shm", FileMode.OpenOrCreate,
            FileAccess.ReadWrite, FileShare.ReadWrite);
        stream.SetLength(32768);
        var mapping = MemoryMappedFile.CreateFromFile(stream, null, 0,
            MemoryMappedFileAccess.ReadWrite, HandleInheritability.None, leaveOpen: true);
        var view = mapping.CreateViewAccessor();
        var releases = Task.Run(async () =>
        {
            await release.Task;
            await Task.Delay(100);
            view.Dispose();
            mapping.Dispose();
            stream.Dispose();
        });
        try
        {
            release.SetResult();
            var reopened = await RepositoryDatabase.OpenExistingAsync(repository.RepositoryPath);
            Assert.Equal(identity, reopened.Identity);
            await using var connection = await reopened.OpenConnectionAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "PRAGMA integrity_check;";
            Assert.Equal("ok", await command.ExecuteScalarAsync());
        }
        finally { release.TrySetResult(); await releases; }
    }

    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern void SetLastError(uint error);
}
