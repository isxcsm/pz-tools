using PzTools.Process.Contracts;

namespace PzTools.Backup.Tests;

public sealed class HotKeyGestureTests
{
    [Theory]
    [InlineData("Ctrl+Shift+F9", "Ctrl+Shift+F9")]
    [InlineData("shift+ctrl+f9", "Ctrl+Shift+F9")]
    [InlineData("Control+Alt+B", "Ctrl+Alt+B")]
    [InlineData("F10", "F10")]
    [InlineData("Ctrl+Num+", "Ctrl+Num+")]
    [InlineData("Win+Pause", "Win+Pause")]
    public void Parse_ReadsACombination_AndWritesItInOneForm(string text, string written) =>
        Assert.Equal(written, HotKeyGesture.Parse(text)?.ToString());

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("B")]                 // typing key alone
    [InlineData("Shift+B")]           // a capital letter
    [InlineData("Ctrl+Ctrl+B")]
    [InlineData("Ctrl+Banana")]
    [InlineData("Hyper+F9")]
    [InlineData("Ctrl+")]
    public void Parse_RefusesWhatIsNoUsableCombination(string text) => Assert.Null(HotKeyGesture.Parse(text));

    [Fact]
    public void Settings_KeepOneCombinationPerAction_AndFindTwoActionsOnOne()
    {
        var settings = new HotKeySettings();
        Assert.Equal(new Dictionary<HotKeyAction, HotKeyGesture> { [HotKeyAction.SaveLast] = HotKeyGesture.Parse("Ctrl+Shift+F9")!.Value },
            settings.Gestures());
        var both = settings.With(HotKeyAction.ManualBackup, "ctrl+shift+f9");
        Assert.True(both.HasDuplicates());
        Assert.Equal("Ctrl+Shift+F9", both.Normalized().ManualBackup);
        Assert.False(settings.With(HotKeyAction.Status, "Ctrl+F9").HasDuplicates());
        Assert.Equal("", settings.With(HotKeyAction.Status, "nonsense").Normalized().Status);
        Assert.All(Enum.GetValues<HotKeyAction>(), action => Assert.Equal("X", settings.With(action, "X").Get(action)));
    }
}
