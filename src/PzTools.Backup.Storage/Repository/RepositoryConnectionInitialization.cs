using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Data.Sqlite;

namespace PzTools.Backup.Storage.Repository;

// Only connection configuration and read-only probes belong in initialize.
// Application transactions, DDL, captures and commits must NEVER be replayed here.
internal static class RepositoryConnectionInitialization
{
    internal const int MaximumAttempts = 5;

    internal static async Task<(SqliteConnection Connection, T Value)> OpenAsync<T>(
        Func<SqliteConnection> createConnection,
        Func<SqliteConnection, CancellationToken, Task<T>> initialize,
        CancellationToken cancellationToken,
        Func<SqliteConnection, int>? systemError = null)
    {
        for (var attempt = 0; ; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var connection = createConnection();
            var transferred = false;
            try
            {
                await connection.OpenAsync(cancellationToken);
                var value = await initialize(connection, cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                transferred = true;
                return (connection, value);
            }
            catch (SqliteException exception) when (CanRetry(exception, attempt, connection, systemError ?? ReadSystemError))
            {
                // Windows can still have the old WAL-index mapping open after a
                // killed process. Re-open a fresh handle, never delete WAL/SHM files.
                Trace.TraceWarning("repository-connection-retry: attempt={0}; sqlite=1546; win32=1224",
                    attempt + 1);
            }
            finally
            {
                if (!transferred) await connection.DisposeAsync();
            }
            await Task.Delay(50 << attempt, cancellationToken);
        }
    }

    // The filter runs while the failed connection is still open, so SQLite can still be asked.
    private static bool CanRetry(SqliteException exception, int attempt, SqliteConnection connection,
        Func<SqliteConnection, int> systemError) =>
        OperatingSystem.IsWindows()
        && exception.SqliteErrorCode == 10
        && exception.SqliteExtendedErrorCode == 1546 // SQLITE_IOERR_TRUNCATE
        && attempt + 1 < MaximumAttempts
        && systemError(connection) == 1224; // ERROR_USER_MAPPED_FILE; not a generic I/O retry.

    // The Windows error SQLite itself recorded for this connection's failure. The thread's own
    // last-error value is not usable here: by the time managed code sees the exception, the
    // runtime may already have replaced it, which made the retry depend on what else had run.
    private static int ReadSystemError(SqliteConnection connection)
    {
        try
        {
            var handle = connection.Handle;
            return handle is null || handle.IsInvalid ? 0 : sqlite3_system_errno(handle.DangerousGetHandle());
        }
        catch (Exception exception) when (exception is DllNotFoundException or EntryPointNotFoundException
            or InvalidOperationException or ObjectDisposedException)
        {
            return 0; // Unknown cause: do not retry.
        }
    }

    [DllImport("e_sqlite3", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    private static extern int sqlite3_system_errno(nint database);
}
