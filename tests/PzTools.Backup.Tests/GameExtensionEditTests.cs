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

        var firstOn = controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.Enabled, true);
        try
        {
            await firstReadEntered.Task.WaitAsync(TimeSpan.FromSeconds(10));
            // The first edit owns the gate, so every following intent is queued before it can finish.
            var off = controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.Enabled, false);
            var force = controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.ForceVersion, true);
            var reverse = controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.Reverse, false);
            var finalOn = controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.Enabled, true);
            var steering = controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.Steering, false);
            releaseFirstRead.Set();
            await Task.WhenAll(firstOn, off, force, reverse, finalOn, steering);
        }
        finally { releaseFirstRead.Set(); }

        var saved = new ExtensionSettingsStore(temp.Path).Read();
        Assert.Equal(6, saved.Revision);
        Assert.Equal(new ExtensionPreference(true, true, new(true, false, false)),
            saved.Extensions[ExtensionIds.VehicleDrivetrain]);
    }

    [Fact]
    public async Task ConcurrentNarrowEditsMergeWithoutLosingEarlierChanges()
    {
        using var temp = new TempDirectory();
        var controller = new GameExtensionController(temp.Path, new RevisionedViewStore());
        await Task.WhenAll(
            controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.Enabled, true),
            controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.ForceVersion, true),
            controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.Torque, false),
            controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.Reverse, false),
            controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.Steering, false));

        var saved = new ExtensionSettingsStore(temp.Path).Read();
        Assert.Equal(5, saved.Revision);
        Assert.Equal(new ExtensionPreference(true, true, new(false, false, false)),
            saved.Extensions[ExtensionIds.VehicleDrivetrain]);
    }

    [Theory]
    [InlineData(GameExtensionSetting.Torque, false)]
    [InlineData(GameExtensionSetting.Torque, true)]
    [InlineData(GameExtensionSetting.Reverse, false)]
    [InlineData(GameExtensionSetting.Reverse, true)]
    [InlineData(GameExtensionSetting.Steering, false)]
    [InlineData(GameExtensionSetting.Steering, true)]
    public async Task AFeatureEditPreservesOtherFeaturesAndCommonPreferences(GameExtensionSetting setting, bool value)
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.Path);
        var original = new VehicleDrivetrainPreference(!value, !value, !value);
        store.SetPreference(ExtensionIds.VehicleDrivetrain, new(true, true, original), 0);
        var controller = new GameExtensionController(temp.Path, new RevisionedViewStore());

        var result = await controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, setting, value);

        var expected = setting switch
        {
            GameExtensionSetting.Torque => original with { TorqueEnabled = value },
            GameExtensionSetting.Reverse => original with { ReverseEnabled = value },
            _ => original with { SteeringEnabled = value }
        };
        var card = result.Cards.Single(item => item.Definition.Id == ExtensionIds.VehicleDrivetrain);
        Assert.Equal(new ExtensionPreference(true, true, expected), store.Read().Extensions[card.Definition.Id]);
        Assert.Equal(expected, card.VehicleDrivetrain);
        Assert.Equal(2, card.SettingsRevision);
    }

    [Fact]
    public async Task EditsAcrossExtensionsShareSerializationWithoutReplacingOtherPreferences()
    {
        using var temp = new TempDirectory();
        var catalogue = temp.GetPath("catalog.tsv");
        File.WriteAllText(catalogue, Row("pztools.test-save", ExtensionCapabilities.SavePreparation) + "\n"
            + Row(ExtensionIds.VehicleDrivetrain, ExtensionCapabilities.VehicleDrivetrain));
        var controller = new GameExtensionController(temp.Path, new RevisionedViewStore(), cataloguePath: catalogue);
        await Task.WhenAll(
            controller.ApplyEditAsync("pztools.test-save", GameExtensionSetting.Enabled, true),
            controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.Reverse, false),
            controller.ApplyEditAsync("pztools.test-save", GameExtensionSetting.ForceVersion, true));

        var saved = new ExtensionSettingsStore(temp.Path).Read();
        Assert.Equal(3, saved.Revision);
        Assert.Equal(new ExtensionPreference(true, true), saved.Extensions["pztools.test-save"]);
        Assert.Equal(new ExtensionPreference(false, false, new(true, false, true)),
            saved.Extensions[ExtensionIds.VehicleDrivetrain]);
    }

    [Fact]
    public async Task EditReadsExternalChangesInsteadOfThePreviouslyPublishedCard()
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.Path);
        var controller = new GameExtensionController(temp.Path, new RevisionedViewStore());
        await controller.RefreshAsync();
        var externalOptions = new VehicleDrivetrainPreference(false, false, true);
        store.SetPreference(ExtensionIds.VehicleDrivetrain, new(true, false, externalOptions), 0);

        var result = await controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.ForceVersion, true);

        var card = result.Cards.Single(item => item.Definition.Id == ExtensionIds.VehicleDrivetrain);
        Assert.True(card.Enabled);
        Assert.True(card.ForceVersion);
        Assert.Equal(externalOptions, card.VehicleDrivetrain);
        Assert.Equal(2, card.SettingsRevision);
    }

    [Fact]
    public async Task ExternalWriteAfterIntentAdmissionIsRejectedWithoutOverwritingItsValues()
    {
        using var temp = new TempDirectory();
        var catalogue = temp.GetPath("catalog.tsv");
        File.WriteAllText(catalogue, Row(ExtensionIds.VehicleDrivetrain, ExtensionCapabilities.VehicleDrivetrain));
        var store = new ExtensionSettingsStore(temp.GetPath("runtime"));
        var external = new ExtensionPreference(true, false, new(false, true, false));
        var reads = 0;
        var controller = new GameExtensionController(temp.GetPath("runtime"), new RevisionedViewStore(),
            gameVersion: () =>
            {
                // First read admits the intent. The service rereads before its revision-checked commit.
                if (++reads == 2) store.SetPreference(ExtensionIds.VehicleDrivetrain, external, 0);
                return "42.20";
            }, cataloguePath: catalogue);

        await Assert.ThrowsAsync<ExtensionSettingsConflictException>(() =>
            controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.ForceVersion, true));

        var saved = store.Read();
        Assert.Equal(1, saved.Revision);
        Assert.Equal(external, saved.Extensions[ExtensionIds.VehicleDrivetrain]);
        var retried = await controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.ForceVersion, true);
        var card = Assert.Single(retried.Cards);
        Assert.True(card.Enabled);
        Assert.True(card.ForceVersion);
        Assert.Equal(external.VehicleDrivetrain, card.VehicleDrivetrain);
        Assert.Equal(2, card.SettingsRevision);
    }

    [Theory]
    [InlineData("pztools.test-save", GameExtensionSetting.Torque)]
    [InlineData("pztools.test-save", GameExtensionSetting.Reverse)]
    [InlineData("pztools.test-save", GameExtensionSetting.Steering)]
    [InlineData("pztools.another-driver", GameExtensionSetting.Torque)]
    public async Task VehicleOptionsCannotBeRoutedToAnotherModule(string id, GameExtensionSetting setting)
    {
        using var temp = new TempDirectory();
        var catalogue = temp.GetPath("catalog.tsv");
        var capability = id == "pztools.test-save" ? ExtensionCapabilities.SavePreparation : ExtensionCapabilities.VehicleDrivetrain;
        File.WriteAllText(catalogue, Row(id, capability));
        var controller = new GameExtensionController(temp.GetPath("runtime"), new RevisionedViewStore(), cataloguePath: catalogue);

        await Assert.ThrowsAsync<InvalidDataException>(() => controller.ApplyEditAsync(id, setting, false));

        Assert.Equal(0, new ExtensionSettingsStore(temp.GetPath("runtime")).Read().Revision);
    }

    [Theory]
    [InlineData(GameExtensionSetting.Enabled)]
    [InlineData(GameExtensionSetting.ForceVersion)]
    [InlineData(GameExtensionSetting.Torque)]
    public async Task MissingModuleIsReportedAsARecoverableInvalidDataFailure(GameExtensionSetting setting)
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
        File.WriteAllText(catalogue, Row(ExtensionIds.VehicleDrivetrain, "unknown.vehicle.v1"));
        var controller = new GameExtensionController(temp.GetPath("runtime"), new RevisionedViewStore(), cataloguePath: catalogue);

        await Assert.ThrowsAsync<InvalidDataException>(() =>
            controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.Torque, false));

        Assert.False(File.Exists(new ExtensionSettingsStore(temp.GetPath("runtime")).FilePath));
    }

    [Fact]
    public async Task RepeatedSameValueDoesNotAdvanceSettingsOrViewRevisions()
    {
        using var temp = new TempDirectory();
        var views = new RevisionedViewStore();
        var controller = new GameExtensionController(temp.Path, views);
        await controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.Reverse, false);
        var first = views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, 0);

        await controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.Reverse, false);

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
            controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, GameExtensionSetting.Enabled, true, cancellation.Token));
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() =>
            controller.ApplyEditAsync(ExtensionIds.VehicleDrivetrain, (GameExtensionSetting)99, true));
        Assert.False(File.Exists(new ExtensionSettingsStore(temp.Path).FilePath));
    }

    private static string Row(string id, string capability) => string.Join('\t', id, "0.2.0", "pztools.extensions.test",
        "pztools.extensions.test.Provider", "test.jar", "All", "-", "-", "Extension.Test.Title", "Extension.Test.Description", capability);
}
