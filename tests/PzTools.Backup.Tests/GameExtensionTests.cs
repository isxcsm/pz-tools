using PzTools.GameExtensions;

namespace PzTools.Backup.Tests;

public sealed class GameExtensionTests
{
    [Fact]
    public void FirstReadDoesNotCreateSettingsAndEnabledIsNotApplied()
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.GetPath("runtime"));
        var service = new GameExtensionService(store, () => "42.20");
        var card = Assert.Single(service.ReadCards());
        Assert.Equal(ExtensionIds.VehicleDrivetrain, card.Definition.Id);
        Assert.False(card.Enabled);
        Assert.False(File.Exists(store.FilePath));
        var enabled = Assert.Single(service.SetEnabled(card.Definition.Id, true, card.SettingsRevision));
        Assert.True(enabled.Enabled);
        Assert.Equal("runtime-pending", enabled.StatusCode);
    }

    [Fact]
    public void PreferencesRoundTripAndStaleWritesDoNotOverwriteOtherClients()
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.GetPath("runtime"));
        store.SetEnabled("pztools.other-module", true, 0);
        var current = store.SetEnabled("pztools.test-save", true, 1);
        Assert.Throws<ExtensionSettingsConflictException>(() => store.SetEnabled("pztools.test-save", false, 1));
        var reopened = new ExtensionSettingsStore(temp.GetPath("runtime"));
        Assert.True(reopened.Read().Extensions["pztools.test-save"].Enabled);
        reopened.SetEnabled("pztools.test-save", false, current.Revision);
        Assert.True(reopened.Read().Extensions["pztools.other-module"].Enabled);
    }

    [Theory]
    [InlineData("invalid json")]
    [InlineData("{\"schemaVersion\":9,\"revision\":1,\"extensions\":{}}")]
    public void RejectedSettingsAreNeverRewritten(string original)
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.GetPath("runtime"));
        Directory.CreateDirectory(Path.GetDirectoryName(store.FilePath)!);
        File.WriteAllText(store.FilePath, original);
        Assert.Throws<InvalidDataException>(() => store.SetEnabled("pztools.test-save", true, 0));
        Assert.Equal(original, File.ReadAllText(store.FilePath));
    }

    [Fact]
    public async Task UnsupportedProviderFallsBackBeforeStartingExactlyOnce()
    {
        var standard = new Provider("standard");
        var module = new Provider("module", supported: false);
        var result = await new GameSaveProviderRouter(standard, module).PrepareAsync("save", true);
        Assert.Equal(1, standard.Executions);
        Assert.Equal(0, module.Executions);
        Assert.Equal(SaveCompletionKind.StandardCallReturned, result.Completion);
        Assert.Equal("unsupported-build", result.FallbackReason);
    }

    [Fact]
    public async Task ProviderFailureAfterAdmissionNeverReplaysStandardSave()
    {
        var standard = new Provider("standard");
        var module = new Provider("module", failure: new IOException("commit outcome unknown"));
        await Assert.ThrowsAsync<IOException>(() => new GameSaveProviderRouter(standard, module).PrepareAsync("save", true));
        Assert.Equal(0, standard.Executions);
        Assert.Equal(1, module.Executions);
    }

    [Fact]
    public async Task DisabledProviderIsNotInspectedOrExecuted()
    {
        var module = new Provider("module", failure: new IOException());
        var result = await new GameSaveProviderRouter(new Provider("standard"), module).PrepareAsync("save", false);
        Assert.Equal("standard", result.ProviderId);
        Assert.Equal(0, module.Inspections);
        Assert.Equal(0, module.Executions);
    }

    [Fact]
    public void RemovedSavePreferencesDoNotRestoreAnExtensionCardOrChangeVehicleSettings()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("runtime");
        var store = new ExtensionSettingsStore(root);
        store.SetPreference("pztools.seamless-save", new(true, true), 0);
        var vehicle = new ExtensionPreference(true, false, new(false, true, false));
        store.SetPreference(ExtensionIds.VehicleDrivetrain, vehicle, 1);
        var original = File.ReadAllText(store.FilePath);
        var service = new GameExtensionService(store, () => "42.20");
        var card = Assert.Single(service.ReadCards());
        Assert.Equal(ExtensionIds.VehicleDrivetrain, card.Definition.Id);
        Assert.Equal(vehicle.Enabled, card.Enabled);
        Assert.Equal(vehicle.VehicleDrivetrain, card.VehicleDrivetrain);
        Assert.Throws<ArgumentException>(() => service.SetEnabled("pztools.seamless-save", true, 2));
        Assert.Equal(original, File.ReadAllText(store.FilePath));
    }

    private sealed class Provider(string id, bool supported = true, Exception? failure = null) : IGameSaveProvider
    {
        public string Id => id;
        public int Inspections { get; private set; }
        public int Executions { get; private set; }
        public ValueTask<SaveProviderSupport> InspectAsync(string sourcePath, CancellationToken cancellationToken)
        {
            Inspections++;
            return ValueTask.FromResult(new SaveProviderSupport(supported, supported ? null : "unsupported-build"));
        }
        public Task<SavePreparationReceipt> PrepareAsync(string sourcePath, CancellationToken cancellationToken)
        {
            Executions++;
            if (failure is not null) return Task.FromException<SavePreparationReceipt>(failure);
            return Task.FromResult(new SavePreparationReceipt(id, SaveCompletionKind.StandardCallReturned, "returned"));
        }
    }
}
