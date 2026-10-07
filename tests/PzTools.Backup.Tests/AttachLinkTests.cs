using PzTools.GameBridge;

namespace PzTools.Backup.Tests;

/// <summary>The helper launch the runtime stream and the extension lease share, and how either reads a failed attach.</summary>
public sealed class AttachLinkTests
{
    [Theory]
    [InlineData("PZTOOLS-ATTACH-FAILED\tbootstrap-version\tjava.io.IOException: Restart the game to use the updated bridge; no save request was sent",
        "restart-required")]
    [InlineData("PZTOOLS-ATTACH-FAILED\thandshake\tjava.io.IOException: Bootstrap request still active", "busy")]
    [InlineData("PZTOOLS-ATTACH-FAILED\tattach\tcom.sun.tools.attach.AttachNotSupportedException: The VM does not support the attach mechanism",
        AttachDiagnostics.DisabledCode)]
    [InlineData("PZTOOLS-ATTACH-FAILED\tattach\tjava.io.IOException: Connection refused", "runtime-unavailable")]
    public void EitherLink_ReadsAFailedAttachAlike(string output, string code)
    {
        foreach (var link in new[] { "Runtime observer", "Continuous extension" })
        {
            var failure = AttachLink.Failure(link, Environment.ProcessId, output, 1, @"C:\App\game-bridge");
            Assert.Equal(code, failure.Code);
            // Any other cause stays the link's own failure, with what the log needs to find it.
            if (code == "runtime-unavailable")
            {
                Assert.Contains(link + " attach failed.", failure.Message);
                Assert.NotNull(failure.Diagnostics);
            }
        }
    }

    [Fact]
    public async Task EitherLink_WithoutTheBridge_IsNotBuilt()
    {
        using var temp = new TempDirectory();
        var bridge = temp.GetPath("missing-bridge");
        var runtime = await Assert.ThrowsAsync<GameSaveException>(async () =>
        {
            await foreach (var _ in new GameRuntimeClient(bridge).WatchAsync(1)) { }
        });
        Assert.Equal("bridge-not-built", runtime.Code);
        var extensions = await Assert.ThrowsAsync<GameSaveException>(() => GameExtensionClient.ConnectAsync(bridge, 1, CancellationToken.None));
        Assert.Equal("bridge-not-built", extensions.Code);
    }
}
