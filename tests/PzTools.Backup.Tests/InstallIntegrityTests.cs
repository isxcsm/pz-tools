using System.Security.Cryptography;
using PzTools.App.Core;

namespace PzTools.Backup.Tests;

/// <summary>The app folder is checked against the list of files it was published with.</summary>
public sealed class InstallIntegrityTests
{
    // A published folder: its files, and the list publish-app.ps1 writes of them.
    private static string Publish(TempDirectory temp, params (string Path, string Text)[] files)
    {
        var root = temp.GetPath("app");
        var lines = new List<string> { "PZTOOLS-FILES\t1" };
        foreach (var (path, text) in files.OrderBy(file => file.Path, StringComparer.Ordinal))
        {
            var full = Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(full)!);
            File.WriteAllText(full, text);
            var bytes = File.ReadAllBytes(full);
            lines.Add($"{Convert.ToHexStringLower(SHA256.HashData(bytes))}\t{bytes.Length}\t{path}");
        }
        File.WriteAllText(Path.Combine(root, InstallIntegrity.ManifestName), string.Join("\n", lines) + "\n");
        return root;
    }

    private static readonly (string, string)[] Release =
        [("PzTools.App.dll", "app v2"), ("workers/PzTools.Backup.Cli.dll", "backup v2"), ("game-bridge/bridge.jar", "jar v2")];

    [Fact]
    public void AWholeFolder_HasNothingToSay_AndIsRemembered()
    {
        using var temp = new TempDirectory();
        var root = Publish(temp, Release);
        var state = temp.GetPath("data", "install-check.json");
        Assert.Null(InstallIntegrity.Check(root, state));
        Assert.True(File.Exists(state));
        // A file the list does not name (left from an older release) is not used by anything, and not reported.
        File.WriteAllText(Path.Combine(root, "workers", "PzTools.Old.dll"), "old");
        Assert.Null(InstallIntegrity.Check(root, state));
    }

    [Fact]
    public void AReleaseExtractedOverARunningOne_IsToldApart()
    {
        using var temp = new TempDirectory();
        var root = Publish(temp, Release);
        var state = temp.GetPath("install-check.json");
        Assert.Null(InstallIntegrity.Check(root, state));
        // The next release over it: its list is new, so every file is read again; the backup worker was in use and kept
        // its old contents, of the same size.
        Publish(temp, ("PzTools.App.dll", "app v3"), ("workers/PzTools.Backup.Cli.dll", "backup v3"), ("game-bridge/bridge.jar", "jar v3"));
        File.WriteAllText(Path.Combine(root, "workers", "PzTools.Backup.Cli.dll"), "backup v2");
        var problem = InstallIntegrity.Check(root, state);
        Assert.NotNull(problem);
        Assert.Equal(["workers/PzTools.Backup.Cli.dll"], problem.Changed);
        Assert.Empty(problem.Missing);
        Assert.Equal("changed 1: workers/PzTools.Backup.Cli.dll", problem.Describe());
        // Not remembered while broken: put right, it is read whole again and found so.
        File.WriteAllText(Path.Combine(root, "workers", "PzTools.Backup.Cli.dll"), "backup v3");
        Assert.Null(InstallIntegrity.Check(root, state));
    }

    [Fact]
    public void AMissingFile_OrOneOfAnotherSize_IsFoundOnEveryStart()
    {
        using var temp = new TempDirectory();
        var root = Publish(temp, Release);
        var state = temp.GetPath("install-check.json");
        Assert.Null(InstallIntegrity.Check(root, state));
        File.Delete(Path.Combine(root, "game-bridge", "bridge.jar"));
        File.WriteAllText(Path.Combine(root, "PzTools.App.dll"), "app v2 changed");
        var problem = InstallIntegrity.Check(root, state)!;
        Assert.Equal(["game-bridge/bridge.jar"], problem.Missing);
        Assert.Equal(["PzTools.App.dll"], problem.Changed);
    }

    [Theory]
    [InlineData(null)]                                                   // a development build has no list
    [InlineData("something else\n")]
    [InlineData("PZTOOLS-FILES\t1\nnot\ta\tline\n")]
    [InlineData("PZTOOLS-FILES\t1\n0000000000000000000000000000000000000000000000000000000000000000\t1\t../outside\n")]
    public void NoList_OrOneNotUnderstood_IsNotChecked(string? manifest)
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("app");
        Directory.CreateDirectory(root);
        if (manifest is not null) File.WriteAllText(Path.Combine(root, InstallIntegrity.ManifestName), manifest);
        Assert.Null(InstallIntegrity.Check(root, temp.GetPath("install-check.json")));
    }
}
