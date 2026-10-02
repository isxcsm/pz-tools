using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Hosting;

namespace PzTools.Backup.Tests;

public sealed class FullScanReparsePointTests
{
    [Fact]
    public async Task FullScan_NeitherCapturesNorEntersAJunctionInsideTheSave()
    {
        if (!OperatingSystem.IsWindows()) return;
        using var temp = new TempDirectory();
        var save = temp.GetPath("save");
        var outside = temp.GetPath("outside");
        Directory.CreateDirectory(save);
        Directory.CreateDirectory(outside);
        await File.WriteAllTextAsync(Path.Combine(save, "map_t.bin"), "save");
        await File.WriteAllTextAsync(Path.Combine(outside, "secret.txt"), "not part of the save");
        var link = Path.Combine(save, "linked");
        var shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell", "v1.0", "powershell.exe");
        var junction = await new ChildProcessHost().RunAsync(shell,
            ["-NoProfile", "-Command", $"New-Item -ItemType Junction -Path '{link.Replace("'", "''")}' -Target '{outside.Replace("'", "''")}'"]);
        Assert.True(junction.ExitCode == 0, junction.StandardError);
        try
        {
            var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
            long sourceId;
            await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
                sourceId = (await repository.AddOrGetSourceAsync(lease, "Sandbox/Save", save)).SourceId;

            await using var scan = await new StreamingFullScanner(new WindowsFileMetadataReader()).ScanAsync(repository, sourceId, save);

            // Only the save's own file: not the junction, and nothing behind it.
            Assert.Equal(1, scan.EntryCount);
        }
        finally
        {
            Directory.Delete(link);
        }
    }
}
