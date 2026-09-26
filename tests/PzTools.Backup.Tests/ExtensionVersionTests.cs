using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class ExtensionVersionTests
{
    [Fact]
    public void VersionRangesFollowSharedComponentCasesAndRejectInvalidBounds()
    {
        foreach (var line in File.ReadAllLines(Path.Combine(AppContext.BaseDirectory, "version-support.tsv")))
        {
            var p = line.Split('|');
            var rule = new GameVersionSupport(Enum.Parse<VersionSupportScope>(p[0]), p[1] == "-" ? null : p[1], p[2] == "-" ? null : p[2]);
            Assert.Equal(bool.Parse(p[4]), rule.Matches(p[3] == "-" ? null : p[3]));
        }
        Assert.Throws<InvalidDataException>(() => new GameVersionSupport(VersionSupportScope.Minor, "42.21", "42.20").Validate());
        Assert.Throws<InvalidDataException>(() => new GameVersionSupport(VersionSupportScope.Major, "42.20").Validate());
        Assert.Throws<InvalidDataException>(() => new GameVersionSupport(VersionSupportScope.All, "42").Validate());
        Assert.Equal(VersionSupportScope.All, Assert.Single(ExtensionCatalog.BuiltIn).SupportedVersions!.Scope);
    }
    [Fact]
    public void MismatchDisablesAdmissionUntilExplicitOverrideAndPreservesPreferencesAcrossVersionChanges()
    {
        using var temp = new TempDirectory();
        string? version = "41.78";
        var definition = Assert.Single(ExtensionCatalog.BuiltIn) with { SupportedVersions = new(VersionSupportScope.Major, "42") };
        var store = new ExtensionSettingsStore(temp.Path);
        var service = new GameExtensionService(store, () => version, () => new[] { definition });
        var first = Assert.Single(service.ReadCards());
        Assert.False(first.CanEnable);
        Assert.Throws<InvalidDataException>(() => service.SetEnabled(definition.Id, true, first.SettingsRevision));
        var forced = Assert.Single(service.SetPreference(definition.Id, true, true, first.SettingsRevision));
        Assert.True(forced.EffectiveEnabled);
        Assert.Equal("forced-version", forced.StatusCode);
        var off = Assert.Single(service.SetEnabled(definition.Id, false, forced.SettingsRevision));
        Assert.True(off.ForceVersion);
        Assert.False(off.Enabled);
        version = "42.20";
        var normal = Assert.Single(service.SetPreference(definition.Id, true, false, off.SettingsRevision));
        Assert.True(normal.EffectiveEnabled);
        version = null;
        var unknown = Assert.Single(service.ReadCards());
        Assert.True(unknown.Enabled); // Desired preference is retained, but cannot be applied blindly.
        Assert.False(unknown.EffectiveEnabled);
        Assert.Equal("version-unknown", unknown.StatusCode);
        version = "43.0";
        Assert.True(Assert.Single(service.ReadCards()).EffectiveEnabled);
        Assert.True(new ExtensionSettingsStore(temp.Path).Read().Extensions[definition.Id].Enabled);
    }
    [Fact]
    public async Task VersionProjectionUsesTheSharedFeedWithoutRewritingSettings()
    {
        using var temp = new TempDirectory();
        string? version = "42.20";
        var store = new ExtensionSettingsStore(temp.Path);
        var views = new RevisionedViewStore();
        var controller = new GameExtensionController(temp.Path, views, gameVersion: () => version);
        var original = await controller.RefreshAsync();
        Assert.Equal("42.20", Assert.Single(original.Cards).GameVersion);
        var revision = views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, 0).ViewRevision;
        await controller.RefreshRuntimeAsync(default);
        Assert.Equal(revision, views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, 0).ViewRevision);
        version = null;
        await controller.RefreshRuntimeAsync(default);
        Assert.Null(Assert.Single(views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, revision).Snapshot!.Cards).GameVersion);
        Assert.False(File.Exists(store.FilePath));
    }
    [Fact]
    public void VersionIsOptionalRuntimeMetadataNotASecondPauseAuthority()
    {
        var id = Guid.NewGuid().ToString("N");
        var state = new RuntimeSnapshot(id, id, id, 0, 0, 1, WorldPhase.Menu, GamePause.Unknown,
            RuntimeMode.LocalSinglePlayer, -1, 0, 0, null, "42.20").Validate();
        Assert.Equal(state, RuntimeJson.Read<RuntimeSnapshot>(RuntimeJson.Write(state)));
        string prefix = $"STATE2\t{id}\t{id}\t{id}\t0\t0\t1\tMenu\tUnknown\tLocalSinglePlayer\t-1\t0\t0\t-\t{RuntimeSnapshot.Capabilities}";
        Assert.Equal(state, RuntimeSnapshot.ParseWire(prefix + "\t" + Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("42.20"))));
    }
}