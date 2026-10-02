using PzTools.App.Core;
using PzTools.GameBridge;
using static PzTools.GameBridge.AttachDiagnostics;

namespace PzTools.Backup.Tests;

/// <summary>A failed attach says where it stopped and why, and names the causes a player can change.</summary>
public sealed class AttachDiagnosticsTests
{
    private static readonly ProcessRights SameRights = new(false, false, true, "ProjectZomboid64.exe", null);

    [Fact]
    public void Read_TakesTheStepAndErrorFromTheHelpersMark()
    {
        var output = "Exception in thread \"main\"\r\n" + FailureMark
            + "\tattach\tcom.sun.tools.attach.AttachNotSupportedException: Unable to open socket file\r\n\tat Foo.bar(Foo.java:1)";
        Assert.Equal(("attach", "com.sun.tools.attach.AttachNotSupportedException: Unable to open socket file"), Read(output));
        // An older helper, or one that crashed before saying: nothing is made up.
        Assert.Equal((null, null), Read("java.lang.OutOfMemoryError"));
    }

    [Fact]
    public void Classify_NamesAttachingTurnedOff_WhateverTheRights()
    {
        Assert.Equal(DisabledCode, Classify("attach",
            "com.sun.tools.attach.AttachNotSupportedException: The VM does not support the attach mechanism", SameRights));
    }

    [Fact]
    public void Classify_BlamesRights_OnlyWhenTheGameHasRightsTheAppLacks()
    {
        var error = "java.io.IOException: Access is denied";
        // The game runs as administrator, the app does not.
        Assert.Equal(ElevationCode, Classify("attach", error, SameRights with { GameElevated = true }));
        // Windows refused even to say: the usual sign of the same.
        Assert.Equal(ElevationCode, Classify("attach", error, SameRights with { GameElevated = null, GameRightsKnown = false }));
        // The same rights, an elevated app, rights not known for another reason, or a later step: not a matter of rights.
        Assert.Equal("attach-failed", Classify("attach", error, SameRights));
        Assert.Equal("attach-failed", Classify("attach", error, SameRights with { AppElevated = true, GameElevated = true }));
        Assert.Equal("attach-failed", Classify("attach", error, SameRights with { GameElevated = null, GameRightsKnown = null }));
        Assert.Equal("attach-failed", Classify("handshake", error, SameRights with { GameElevated = true }));
        Assert.Equal("attach-failed", Classify(null, null, SameRights with { GameElevated = true }));
    }

    [Fact]
    public void Failure_CarriesTheStepAndEnvironment_ForTheLog_WithoutThePaths()
    {
        var folder = Path.Combine(Path.GetTempPath(), "게임 도구");
        // No game with this id: its rights cannot be read, and that is not blamed on rights.
        var failure = Failure(int.MaxValue - 7, FailureMark + "\tbootstrap\tjava.io.IOException: boom", 1, folder);
        Assert.Equal("attach-failed", failure.Code);
        Assert.Equal("[attach-failed] bootstrap: java.io.IOException: boom", failure.Message);
        Assert.Contains("stage=bootstrap", failure.Diagnostics);
        Assert.Contains("exit=1", failure.Diagnostics);
        Assert.Contains("appFolderNonAscii=yes", failure.Diagnostics);
        Assert.Contains("gameElevated=unknown", failure.Diagnostics);
        Assert.DoesNotContain(folder, failure.Diagnostics);
        Assert.True(failure.LinkUnavailable);
    }

    [Fact]
    public void ProfileErrors_NameTheKnownCauses()
    {
        Assert.Equal("ProfileError.Elevation", ProfileRecordingService.ErrorKey("profile-" + ElevationCode));
        Assert.Equal("ProfileError.AttachDisabled", ProfileRecordingService.ErrorKey("profile-" + DisabledCode));
        Assert.Equal("ProfileError.Link", ProfileRecordingService.ErrorKey("profile-attach-failed"));
    }
}
