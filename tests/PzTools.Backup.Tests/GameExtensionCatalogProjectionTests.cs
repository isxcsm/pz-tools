using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class GameExtensionCatalogProjectionTests
{
    [Fact]
    public async Task RepeatedFileCatalogueReadsAndEquivalentRewritesDoNotPublishNewViews()
    {
        using var temp = new TempDirectory();
        var catalogue = temp.GetPath("catalog.tsv");
        var row = string.Join('\t', Fields());
        File.WriteAllText(catalogue, row);
        var views = new RevisionedViewStore();
        var controller = new GameExtensionController(temp.GetPath("runtime"), views,
            gameVersion: () => "42.20.0", cataloguePath: catalogue);
        await controller.RefreshAsync();
        var first = Current(views);
        for (var i = 0; i < 3; i++) await controller.RefreshRuntimeAsync(default);
        AssertUnchanged(views, first.ViewRevision);
        // Neither changed file contents nor a new parse/list identity is itself a UI change.
        File.WriteAllText(catalogue, "# equivalent catalogue\r\n\r\n" + row + "\r\n");
        await controller.RefreshRuntimeAsync(default);
        AssertUnchanged(views, first.ViewRevision);
        await controller.RefreshAsync();
        AssertUnchanged(views, first.ViewRevision);
    }

    [Theory]
    [InlineData(0, "pztools.renamed-save")]
    [InlineData(1, "0.3.0")]
    [InlineData(5, "Major")]
    [InlineData(6, "42.19")]
    [InlineData(7, "42.22")]
    [InlineData(8, "Extension.Test.RenamedTitle")]
    [InlineData(9, "Extension.Test.RenamedDescription")]
    [InlineData(10, ExtensionCapabilities.VehicleDrivetrain)]
    public async Task ChangedFileCatalogueMetadataPublishesExactlyOneNewView(int field, string replacement)
    {
        using var temp = new TempDirectory();
        var catalogue = temp.GetPath("catalog.tsv");
        var fields = Fields();
        File.WriteAllText(catalogue, string.Join('\t', fields));
        var views = new RevisionedViewStore();
        var controller = new GameExtensionController(temp.GetPath("runtime"), views,
            gameVersion: () => "42.20.0", cataloguePath: catalogue);
        await controller.RefreshAsync();
        var first = Current(views);
        fields[field] = replacement;
        if (field == 5) { fields[6] = "42"; fields[7] = "43"; }
        File.WriteAllText(catalogue, string.Join('\t', fields));
        await controller.RefreshRuntimeAsync(default);
        var changed = Current(views);
        Assert.Equal(first.ViewRevision + 1, changed.ViewRevision);
        var expected = Assert.Single(ExtensionCatalog.ReadFile(catalogue));
        var actual = Assert.Single(changed.Snapshot!.Cards).Definition;
        Assert.Equal(expected.Id, actual.Id);
        Assert.Equal(expected.Version, actual.Version);
        Assert.Equal(expected.SupportedVersions, actual.SupportedVersions);
        Assert.Equal(expected.TitleKey, actual.TitleKey);
        Assert.Equal(expected.DescriptionKey, actual.DescriptionKey);
        Assert.Equal(expected.ActivationKind, actual.ActivationKind);
        await controller.RefreshRuntimeAsync(default);
        AssertUnchanged(views, changed.ViewRevision);
    }

    [Fact]
    public async Task FileCatalogueDedupDoesNotHideExternalPreferencesOrObservedGameVersionChanges()
    {
        using var temp = new TempDirectory();
        var catalogue = temp.GetPath("catalog.tsv");
        File.WriteAllText(catalogue, string.Join('\t', Fields()));
        var root = temp.GetPath("runtime");
        var views = new RevisionedViewStore();
        string? gameVersion = "42.20.0";
        var controller = new GameExtensionController(root, views, gameVersion: () => gameVersion, cataloguePath: catalogue);
        await controller.RefreshAsync();
        var first = Current(views);
        var id = Assert.Single(first.Snapshot!.Cards).Definition.Id;
        new ExtensionSettingsStore(root).SetPreference(id, new(true, true), 0);
        await controller.RefreshRuntimeAsync(default);
        var preferenceChanged = Current(views);
        Assert.Equal(first.ViewRevision + 1, preferenceChanged.ViewRevision);
        var enabled = Assert.Single(preferenceChanged.Snapshot!.Cards);
        Assert.True(enabled.Enabled);
        Assert.True(enabled.ForceVersion);
        Assert.Equal(1, enabled.SettingsRevision);
        gameVersion = "42.22.0";
        await controller.RefreshRuntimeAsync(default);
        var versionChanged = Current(views);
        Assert.Equal(preferenceChanged.ViewRevision + 1, versionChanged.ViewRevision);
        var mismatched = Assert.Single(versionChanged.Snapshot!.Cards);
        Assert.Equal(gameVersion, mismatched.GameVersion);
        Assert.False(mismatched.VersionMatches);
        Assert.Equal("forced-version", mismatched.StatusCode);
        await controller.RefreshRuntimeAsync(default);
        AssertUnchanged(views, versionChanged.ViewRevision);
    }

    private static string[] Fields() => ["pztools.test-save", "0.2.0", "pztools.extensions.test",
        "pztools.extensions.test.Provider", "test.jar", "Minor", "42.20", "42.21",
        "Extension.Test.Title", "Extension.Test.Description", ExtensionCapabilities.SavePreparation];

    private static ViewReadResult<GameExtensionsView> Current(RevisionedViewStore views) =>
        views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, 0);

    private static void AssertUnchanged(RevisionedViewStore views, long revision)
    {
        var current = views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, revision);
        Assert.False(current.Modified);
        Assert.Equal(revision, current.ViewRevision);
    }
}
