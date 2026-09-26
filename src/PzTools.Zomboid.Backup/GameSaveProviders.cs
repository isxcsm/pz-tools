using PzTools.GameExtensions;
using PzTools.SaveBridge;

namespace PzTools.Zomboid.Backup;

internal sealed class StandardGameSaveProvider(Func<string, CancellationToken, Task<string>> save)
    : IGameSaveProvider
{
    public string Id => "pztools.standard-save";
    public ValueTask<SaveProviderSupport> InspectAsync(string sourcePath, CancellationToken cancellationToken) =>
        ValueTask.FromResult(new SaveProviderSupport(true));
    public async Task<SavePreparationReceipt> PrepareAsync(string sourcePath, CancellationToken cancellationToken) =>
        new(Id, SaveCompletionKind.StandardCallReturned, await save(sourcePath, cancellationToken));
}

/// <summary>No real-game adapter is qualified yet. The foundation must not masquerade as asynchronous saving.</summary>
internal sealed class SeamlessSaveAvailability : IGameSaveProvider
{
    public string Id => ExtensionIds.SeamlessSave;
    public ValueTask<SaveProviderSupport> InspectAsync(string sourcePath, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return ValueTask.FromResult(new SaveProviderSupport(false, "adapter-validation-required"));
    }
    public Task<SavePreparationReceipt> PrepareAsync(string sourcePath, CancellationToken cancellationToken) =>
        throw new GameSaveException("extension-unavailable", "The seamless-save adapter has not been qualified for this game build.");
}

public static class ConfiguredGameSaveProviders
{
    public static Func<string, CancellationToken, Task<string>> Create(GameSaveClient client, string runtimeRoot) =>
        Create(client.SaveRunningGameAsync, runtimeRoot, new BridgeGameSaveProvider(client));

    public static Func<string, CancellationToken, Task<string>> Create(
        Func<string, CancellationToken, Task<string>> standardSave, string runtimeRoot, IGameSaveProvider? extension = null)
    {
        var store = new ExtensionSettingsStore(runtimeRoot);
        var router = new GameSaveProviderRouter(new StandardGameSaveProvider(standardSave), extension ?? new SeamlessSaveAvailability());
        return async (path, token) =>
        {
            bool enabled;
            string? configurationFailure = null;
            try { enabled = store.Read().Extensions.GetValueOrDefault(ExtensionIds.SeamlessSave)?.Enabled ?? false; }
            catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException)
            {
                enabled = false;
                configurationFailure = "extension-settings-unavailable";
            }
            var result = await router.PrepareAsync(path, enabled, token);
            var fallback = configurationFailure ?? result.FallbackReason;
            return result.Detail + "; provider=" + result.ProviderId + "; completion=" + result.Completion + (fallback is null ? "" : "; extension-fallback=" + fallback);
        };
    }
}
