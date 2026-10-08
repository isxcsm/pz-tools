using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class GameExtensionEditTests
{
    [Fact]
    public async Task QueuedOnOffOnKeepsTheLastIntentAndOtherConcurrentFieldEdits()
    {
        using var temp = new TempDirectory();
        using var releaseFirstRead = new ManualResetEventSlim();
        var firstReadEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var reads = 0;
        var controller = new GameExtensionController(temp.Path, new RevisionedViewStore(), gameVersion: () =>
        {
            if (Interlocked.Increment(ref reads) == 1)
            {
                firstReadEntered.SetResult();
                if (!releaseFirstRead.Wait(TimeSpan.FromSeconds(10)))
                    throw new TimeoutException("The test did not release the first admitted edit.");
            }
            return "42.20";
        });

        var firstOn = controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, GameExtensionSetting.Enabled, true);
        try
        {
            await firstReadEntered.Task.WaitAsync(TimeSpan.FromSeconds(10));
            // The first edit owns the gate, so every following intent is queued before it can finish.
            var off = controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, GameExtensionSetting.Enabled, false);
            var force = controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, GameExtensionSetting.ForceVersion, true);
            var reverse = controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, VehicleDrivetrainExtension.Reverse, false);
            var finalOn = controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, GameExtensionSetting.Enabled, true);
            var steering = controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, VehicleDrivetrainExtension.Steering, false);
            releaseFirstRead.Set();
            await Task.WhenAll(firstOn, off, force, reverse, finalOn, steering);
        }
        finally { releaseFirstRead.Set(); }

        var saved = new ExtensionSettingsStore(temp.Path).Read();
        Assert.Equal(6, saved.Revision);
        // Only the switches edited are saved; the others keep their default (on).
        Assert.Equal(new ExtensionPreference(true, true, Saved((VehicleDrivetrainExtension.Reverse, false), (VehicleDrivetrainExtension.Steering, false))),
            saved.Extensions[VehicleDrivetrainExtension.Id]);
    }

    [Fact]
    public async Task ConcurrentNarrowEditsMergeWithoutLosingEarlierChanges()
    {
        using var temp = new TempDirectory();
        var controller = new GameExtensionController(temp.Path, new RevisionedViewStore());
        await Task.WhenAll(
            controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, GameExtensionSetting.Enabled, true),
            controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, GameExtensionSetting.ForceVersion, true),
            controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, VehicleDrivetrainExtension.Torque, false),
            controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, VehicleDrivetrainExtension.Reverse, false),
            controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, VehicleDrivetrainExtension.Steering, false));

        var saved = new ExtensionSettingsStore(temp.Path).Read();
        Assert.Equal(5, saved.Revision);
        Assert.Equal(new ExtensionPreference(true, true, Saved((VehicleDrivetrainExtension.Torque, false),
            (VehicleDrivetrainExtension.Reverse, false), (VehicleDrivetrainExtension.Steering, false))),
            saved.Extensions[VehicleDrivetrainExtension.Id]);
    }

    [Theory]
    [InlineData(VehicleDrivetrainExtension.Torque, false)]
    [InlineData(VehicleDrivetrainExtension.Torque, true)]
    [InlineData(VehicleDrivetrainExtension.Reverse, false)]
    [InlineData(VehicleDrivetrainExtension.Reverse, true)]
    [InlineData(VehicleDrivetrainExtension.Steering, false)]
    [InlineData(VehicleDrivetrainExtension.Steering, true)]
    [InlineData(VehicleDrivetrainExtension.AreaLight, false)]
    [InlineData(VehicleDrivetrainExtension.AreaLight, true)]
    public async Task AFeatureEditPreservesOtherFeaturesAndCommonPreferences(string setting, bool value)
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.Path);
        var original = VehicleOptions.Of(!value, !value, !value, !value);
        store.SetPreference(VehicleDrivetrainExtension.Id, new(true, true, original), 0);
        var controller = new GameExtensionController(temp.Path, new RevisionedViewStore());

        var result = await controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, setting, value);

        var expected = new Dictionary<string, bool>(original) { [setting] = value };
        var card = result.Cards.Single(item => item.Definition.Id == VehicleDrivetrainExtension.Id);
        Assert.Equal(new ExtensionPreference(true, true, expected), store.Read().Extensions[card.Definition.Id]);
        VehicleOptions.AssertSame(expected, card.Options);
        Assert.Equal(2, card.SettingsRevision);
    }

    [Fact]
    public async Task EditsAcrossExtensionsShareSerializationWithoutReplacingOtherPreferences()
    {
        using var temp = new TempDirectory();
        var catalogue = temp.GetPath("catalog.tsv");
        File.WriteAllText(catalogue, Row("pztools.test-module", ExtensionCapabilities.Continuous) + "\n"
            + Row(VehicleDrivetrainExtension.Id, ExtensionCapabilities.Continuous));
        var controller = new GameExtensionController(temp.Path, new RevisionedViewStore(), cataloguePath: catalogue);
        await Task.WhenAll(
            controller.ApplyEditAsync("pztools.test-module", GameExtensionSetting.Enabled, true),
            controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, VehicleDrivetrainExtension.Reverse, false),
            controller.ApplyEditAsync("pztools.test-module", GameExtensionSetting.ForceVersion, true));

        var saved = new ExtensionSettingsStore(temp.Path).Read();
        Assert.Equal(3, saved.Revision);
        Assert.Equal(new ExtensionPreference(true, true), saved.Extensions["pztools.test-module"]);
        Assert.Equal(new ExtensionPreference(false, false, Saved((VehicleDrivetrainExtension.Reverse, false))),
            saved.Extensions[VehicleDrivetrainExtension.Id]);
    }

    [Fact]
    public async Task EditReadsExternalChangesInsteadOfThePreviouslyPublishedCard()
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.Path);
        var controller = new GameExtensionController(temp.Path, new RevisionedViewStore());
        await controller.RefreshAsync();
        var externalOptions = VehicleOptions.Of(false, false, true);
        store.SetPreference(VehicleDrivetrainExtension.Id, new(true, false, externalOptions), 0);

        var result = await controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, GameExtensionSetting.ForceVersion, true);

        var card = result.Cards.Single(item => item.Definition.Id == VehicleDrivetrainExtension.Id);
        Assert.True(card.Enabled);
        Assert.True(card.ForceVersion);
        VehicleOptions.AssertSame(externalOptions, card.Options);
        Assert.Equal(2, card.SettingsRevision);
    }

    [Fact]
    public async Task ExternalWriteAfterIntentAdmissionIsRejectedWithoutOverwritingItsValues()
    {
        using var temp = new TempDirectory();
        var catalogue = temp.GetPath("catalog.tsv");
        File.WriteAllText(catalogue, Row(VehicleDrivetrainExtension.Id, ExtensionCapabilities.Continuous));
        var store = new ExtensionSettingsStore(temp.GetPath("runtime"));
        var external = new ExtensionPreference(true, false, VehicleOptions.Of(false, true, false));
        var reads = 0;
        var controller = new GameExtensionController(temp.GetPath("runtime"), new RevisionedViewStore(),
            gameVersion: () =>
            {
                // The first read admits the intent. The store rereads under its lock before its revision-checked commit.
                if (++reads == 1) store.SetPreference(VehicleDrivetrainExtension.Id, external, 0);
                return "42.20";
            }, cataloguePath: catalogue);

        await Assert.ThrowsAsync<ExtensionSettingsConflictException>(() =>
            controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, GameExtensionSetting.ForceVersion, true));

        var saved = store.Read();
        Assert.Equal(1, saved.Revision);
        Assert.Equal(external, saved.Extensions[VehicleDrivetrainExtension.Id]);
        var retried = await controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, GameExtensionSetting.ForceVersion, true);
        var card = Assert.Single(retried.Cards);
        Assert.True(card.Enabled);
        Assert.True(card.ForceVersion);
        VehicleOptions.AssertSame(external.Options, card.Options);
        Assert.Equal(2, card.SettingsRevision);
    }

    [Theory]
    [InlineData("pztools.test-save", VehicleDrivetrainExtension.Torque)]
    [InlineData("pztools.test-save", VehicleDrivetrainExtension.Reverse)]
    [InlineData("pztools.test-save", VehicleDrivetrainExtension.Steering)]
    [InlineData("pztools.another-driver", VehicleDrivetrainExtension.Torque)]
    public async Task VehicleOptionsCannotBeRoutedToAnotherModule(string id, string setting)
    {
        using var temp = new TempDirectory();
        var catalogue = temp.GetPath("catalog.tsv");
        var capability = id == "pztools.test-save" ? ExtensionCapabilities.SavePreparation : ExtensionCapabilities.Continuous;
        File.WriteAllText(catalogue, Row(id, capability));
        var controller = new GameExtensionController(temp.GetPath("runtime"), new RevisionedViewStore(), cataloguePath: catalogue);

        await Assert.ThrowsAsync<InvalidDataException>(() => controller.ApplyEditAsync(id, setting, false));

        Assert.Equal(0, new ExtensionSettingsStore(temp.GetPath("runtime")).Read().Revision);
    }

    [Theory]
    [InlineData(GameExtensionSetting.Enabled)]
    [InlineData(GameExtensionSetting.ForceVersion)]
    [InlineData(VehicleDrivetrainExtension.Torque)]
    public async Task MissingModuleIsReportedAsARecoverableInvalidDataFailure(string setting)
    {
        using var temp = new TempDirectory();
        var controller = new GameExtensionController(temp.Path, new RevisionedViewStore());
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            controller.ApplyEditAsync("pztools.missing-extension", setting, true));
        Assert.False(File.Exists(new ExtensionSettingsStore(temp.Path).FilePath));
    }

    [Fact]
    public async Task UnsupportedCatalogueCapabilityCannotBeEdited()
    {
        using var temp = new TempDirectory();
        var catalogue = temp.GetPath("catalog.tsv");
        File.WriteAllText(catalogue, Row(VehicleDrivetrainExtension.Id, "unknown.vehicle.v1"));
        var controller = new GameExtensionController(temp.GetPath("runtime"), new RevisionedViewStore(), cataloguePath: catalogue);

        await Assert.ThrowsAsync<InvalidDataException>(() =>
            controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, VehicleDrivetrainExtension.Torque, false));

        Assert.False(File.Exists(new ExtensionSettingsStore(temp.GetPath("runtime")).FilePath));
    }

    [Fact]
    public async Task RepeatedSameValueDoesNotAdvanceSettingsOrViewRevisions()
    {
        using var temp = new TempDirectory();
        var views = new RevisionedViewStore();
        var controller = new GameExtensionController(temp.Path, views);
        await controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, VehicleDrivetrainExtension.Reverse, false);
        var first = views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, 0);

        await controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, VehicleDrivetrainExtension.Reverse, false);

        Assert.Equal(1, new ExtensionSettingsStore(temp.Path).Read().Revision);
        Assert.False(views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, first.ViewRevision).Modified);
    }

    [Fact]
    public async Task CancellationBeforeAdmissionAndUnknownSettingsDoNotWrite()
    {
        using var temp = new TempDirectory();
        var controller = new GameExtensionController(temp.Path, new RevisionedViewStore());
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, GameExtensionSetting.Enabled, true, cancellation.Token));
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, "noSuchOption", true));
        Assert.False(File.Exists(new ExtensionSettingsStore(temp.Path).FilePath));
    }

    private static Dictionary<string, bool> Saved(params (string Key, bool Value)[] options) =>
        options.ToDictionary(option => option.Key, option => option.Value, StringComparer.Ordinal);

    private static string Row(string id, string capability) => string.Join('\t', id, "0.2.0", "pztools.extensions.test",
        "pztools.extensions.test.Provider", "test.jar", "All", "-", "-", "Extension.Test.Title", "Extension.Test.Description", capability);
}
