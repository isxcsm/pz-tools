using System.Collections.Concurrent;
using System.Runtime.CompilerServices;

namespace PzTools.Backup.Tests;

// Test-host-only native diagnostics. No SQL calls or disk I/O inside the callback.
internal static class NativeSqliteDiagnostics
{
    private static readonly ConcurrentQueue<string> messages = new();
    private static int registrationResult;

#pragma warning disable CA2255 // Test assembly must install the error sink before test execution.
    [ModuleInitializer]
    internal static void Initialize()
    {
        SQLitePCL.Batteries_V2.Init();
        registrationResult = SQLitePCL.raw.sqlite3_config_log(
            new SQLitePCL.strdelegate_log((state, code, message) =>
            {
                if ((code & 255) != 10) return;
                messages.Enqueue($"{code}: {message}");
                while (messages.Count > 32) messages.TryDequeue(out _);
            }), null);
    }
#pragma warning restore CA2255

    internal static string Snapshot() => $"logger={registrationResult}; " + string.Join("\n", messages);
}

public sealed class CrashRecoveryStressTests
{
    [Theory]
    [InlineData("BeforePackFlush", false)]
    [InlineData("AfterPackPromotion", false)]
    [InlineData("BeforeRepositoryCommit", false)]
    [InlineData("DuringRepositoryCommit", false)]
    [InlineData("AfterRepositoryCommit", true)]
    [InlineData("restore", true)]
    public async Task RepeatedProcessTermination_PreservesEveryBoundary(string mode, bool committed)
    {
        // Every iteration uses a NEW repository. This is repeated validation,
        // not a retry of a failed operation: the first failure fails the test.
        for (var iteration = 0; iteration < 5; iteration++)
        {
            try
            {
                await new InterruptedOperationRecoveryTests()
                    .KilledProcess_RecoversOldOrCommittedState(mode, committed);
            }
            catch (Exception exception)
            {
                throw new Xunit.Sdk.XunitException(
                    $"mode={mode}; iteration={iteration}; {NativeSqliteDiagnostics.Snapshot()}\n{exception}");
            }
        }
    }
}
