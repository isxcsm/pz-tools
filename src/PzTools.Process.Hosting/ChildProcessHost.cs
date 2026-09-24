using System.Diagnostics;

namespace PzTools.Process.Hosting;

public sealed record ChildProcessResult(
    bool Started,
    int? ExitCode,
    string StandardOutput,
    string StandardError,
    string? FailureCode);

public sealed class ChildProcessHost
{
    public async Task<ChildProcessResult> RunAsync(
        string executable,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken = default,
        Action<string>? standardOutput = null,
        Action<string>? standardError = null,
        bool captureOutput = true, int shutdownGraceMs = 2000)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ArgumentException.ThrowIfNullOrWhiteSpace(executable);
        ArgumentNullException.ThrowIfNull(arguments);
        var startInfo = new ProcessStartInfo
        {
            FileName = Path.GetFullPath(executable),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = new System.Diagnostics.Process { StartInfo = startInfo, EnableRaisingEvents = true };
        try
        {
            if (!process.Start())
            {
                return new ChildProcessResult(false, null, "", "", "launch-failed");
            }
        }
        catch (Exception exception) when (
            exception is InvalidOperationException
            or System.ComponentModel.Win32Exception
            or FileNotFoundException
            or DirectoryNotFoundException)
        {
            return new ChildProcessResult(
                false, null, "", exception.Message, "launch-failed");
        }

        ProcessTreeJob? createdJob = null;
        try
        {
            if (OperatingSystem.IsWindows())
            {
                createdJob = ProcessTreeJob.CreateKillOnClose();
                createdJob.Assign(process);
            }
        }
        catch
        {
            try
            {
                process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            }
            catch (InvalidOperationException)
            {
            }
            finally { createdJob?.Dispose(); }
            throw;
        }

        using var job = createdJob;
        var stdout = ConsumeAsync(process.StandardOutput, standardOutput, captureOutput);
        var stderr = ConsumeAsync(process.StandardError, standardError, captureOutput);
        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            try
            {
                if (!process.HasExited && process.CloseMainWindow())
                {
                    using var grace = new CancellationTokenSource(TimeSpan.FromMilliseconds(shutdownGraceMs));
                    await process.WaitForExitAsync(grace.Token).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException) { }
            catch (InvalidOperationException) when (process.HasExited) { }
            finally
            {
                if (job is not null) job.Terminate();
                else if (!process.HasExited) process.Kill(entireProcessTree: true);
            }
            try
            {
                await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
                await Task.WhenAll(stdout, stderr).ConfigureAwait(false);
            }
            catch (Exception exception) when (
                exception is InvalidOperationException or IOException)
            {
            }
            throw;
        }

        // The managed parent has finished. Non-detached descendants must not keep
        // inherited output pipes open while we drain the final result.
        job?.Terminate();
        return new ChildProcessResult(
            true,
            process.ExitCode,
            await stdout.ConfigureAwait(false),
            await stderr.ConfigureAwait(false),
            process.ExitCode == 0 ? null : "child-failed");
    }

    private static async Task<string> ConsumeAsync(StreamReader reader, Action<string>? consumer, bool captureOutput)
    {
        var output = captureOutput ? new System.Text.StringBuilder() : null;
        Exception? callbackError = null;
        while (await reader.ReadLineAsync().ConfigureAwait(false) is { } line)
        {
            output?.AppendLine(line);
            try { if (callbackError is null) consumer?.Invoke(line); }
            catch (Exception exception) { callbackError = exception; }
        }
        if (callbackError is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(callbackError).Throw();
        return output?.ToString() ?? "";
    }
}
