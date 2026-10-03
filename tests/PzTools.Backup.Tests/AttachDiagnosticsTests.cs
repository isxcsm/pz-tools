using PzTools.App.Core;
using PzTools.GameBridge;
using static PzTools.GameBridge.AttachDiagnostics;

namespace PzTools.Backup.Tests;

/// <summary>A failed attach says where it stopped and why, and names the causes a player can change.</summary>
public sealed class AttachDiagnosticsTests
{
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
    public void Classify_NamesAttachingTurnedOff_AndNothingElse()
    {
        Assert.Equal(DisabledCode,
            Classify("com.sun.tools.attach.AttachNotSupportedException: The VM does not support the attach mechanism"));
        // The app runs as administrator by its manifest: a game's rights are never the cause.
        Assert.Equal("attach-failed", Classify("java.io.IOException: Access is denied"));
        Assert.Equal("attach-failed", Classify(null));
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
    public void Failure_LeavesOutPaths_TheHelpersOwnWordsGave()
    {
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var lockFolder = Path.Combine(profile, ".pztools-bridge");
        var output = FailureMark + "\tlock\tjava.nio.file.AccessDeniedException: " + lockFolder + "\r\n"
            + "\tat sun.nio.fs.WindowsException.translateToIOException(WindowsException.java:89)\r\n"
            + "Caused by: java.io.IOException: D:\\Games\\Someone Else\\ProjectZomboid\\projectzomboid.jar";
        var failure = Failure(int.MaxValue - 7, output, 1, Path.GetTempPath());
        foreach (var text in new[] { failure.Message, failure.Diagnostics! })
        {
            Assert.DoesNotContain(profile, text, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("D:\\Games", text);
        }
        // What the path was is still told: the user's own folder by name, another by its last part.
        Assert.Contains("%USERPROFILE%\\.pztools-bridge", failure.Diagnostics);
        Assert.Contains("…\\projectzomboid.jar", failure.Diagnostics);
    }

    [Fact]
    public void TheGamesAccount_IsReadFromItsProcess_AndPassedToTheHelper()
    {
        // This test's own process stands for the game.
        Assert.Equal(System.Security.Principal.WindowsIdentity.GetCurrent().Name, AccountOf(Environment.ProcessId));
        var start = new System.Diagnostics.ProcessStartInfo("java");
        PassGameAccount(start, Environment.ProcessId);
        Assert.Equal(AccountOf(Environment.ProcessId), start.Environment[GameAccountVariable]);
        // A process that is not there: nothing is said, and the helper takes the account the app was started for.
        Assert.Null(AccountOf(int.MaxValue - 7));
    }

    [Fact]
    public void Failure_SaysWhereTheFilesHandedToTheGameCameFrom()
    {
        var output = HandedMark + "\tpztools-attach-bootstrap.dll=temp-copy\r\n" + FailureMark
            + "\tnative-bootstrap\tcom.sun.tools.attach.AgentLoadException: Failed to load agent library";
        Assert.Contains("handed=pztools-attach-bootstrap.dll=temp-copy;", Failure(int.MaxValue - 7, output, 1, Path.GetTempPath()).Diagnostics);
    }

    [Fact]
    public void ProfileErrors_NameTheKnownCauses()
    {
        Assert.Equal("ProfileError.AttachDisabled", ProfileRecordingService.ErrorKey("profile-" + DisabledCode));
        Assert.Equal("ProfileError.Link", ProfileRecordingService.ErrorKey("profile-attach-failed"));
    }
}
