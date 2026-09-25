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
        CancellationToken cancellationToken)
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
            catch (SqliteException exception) when (CanRetry(exception, attempt))
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

    private static bool CanRetry(SqliteException exception, int attempt) =>
        OperatingSystem.IsWindows()
        && exception.SqliteErrorCode == 10
        && exception.SqliteExtendedErrorCode == 1546 // SQLITE_IOERR_TRUNCATE
        && attempt + 1 < MaximumAttempts
        && GetLastError() == 1224; // ERROR_USER_MAPPED_FILE; not a generic I/O retry.

    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern uint GetLastError();
}
