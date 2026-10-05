using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace PzTools.Backup.Tests;

/// <summary>
/// Source contracts for app behaviour that has no unit to test without launching the window (docs/design/ui-ux-contract.md).
/// </summary>
public sealed class AppUiBehaviourSourceTests
{
    [Fact]
    public void ASaveManagerActionIsNotUnlockedByAFaultedTelemetryProjection()
    {
        var method = Method(Source("MainWindowShell.xaml.cs"), "private bool OtherOperationRunning()");
        Assert.Contains("App.Host?.HasRunningOperation() == true", method);
        Assert.DoesNotContain("IsFaulted(\"telemetry\")", method);
    }

    // Seen in the app: switched from Korean to English, the developer card preview stayed Korean.
    [Fact]
    public void TheCardPreviewIsLocalizedAgainOnALanguageChange()
    {
        var page = Source("SettingsPage.xaml.cs");
        Assert.Contains("LocalizeCardPreview();", Method(page, "internal void ApplyLocalizedText()"));
        var build = Method(page, "private void BuildCardPreview()");
        Assert.DoesNotContain("Localizer.", build);
        Assert.Contains("LocalizeCardPreview();", build);
    }

    // Seen in the app: switching Save game before backup flashed the card light grey between its two colours, as the
    // card's template eased from the opaque caution colour to its nearly transparent default.
    [Fact]
    public void TheGameSaveWarningChangesTheCardsColourAtOnce()
    {
        var warning = Method(Source("SettingsPage.xaml.cs"), "private void ShowGameSaveWarning(");
        var cleared = warning.IndexOf("templateRoot.BackgroundTransition = null;", StringComparison.Ordinal);
        Assert.True(cleared >= 0);
        Assert.True(cleared < warning.IndexOf("GameSaveSettingCard.Background =", StringComparison.Ordinal));
    }

    [Fact]
    public void EveryAttentionCardIsLocalizedAgainOnALanguageChange()
    {
        var shell = Source("MainWindowShell.xaml.cs");
        var localize = Method(shell, "private void ApplyLocalizedText()");
        var cards = XDocument.Parse(Source("MainWindowShell.xaml")).Descendants()
            .Where(element => element.Name.LocalName == "AttentionCard")
            .Select(element => (string)element.Attribute(XName.Get("Name", "http://schemas.microsoft.com/winfx/2006/xaml"))!)
            .ToArray();
        Assert.Contains("InstallCard", cards);
        Assert.Contains("GameMemoryCard", cards);
        foreach (var card in cards) Assert.Contains(card, localize);
        Assert.Contains("ApplyInstallProblem();", localize);
        Assert.Contains("ApplyGameMemory();", localize);
    }

    [Fact]
    public void NoBrushIsReadFromTheApplicationResourcesInCode()
    {
        // Those resolve in Windows' theme, not the one chosen in the app's settings.
        var brush = new Regex(@"Application\.Current\.Resources\[""[^""]*Brush""\]");
        var offenders = AppSources().Where(file => brush.IsMatch(File.ReadAllText(file))).Select(Path.GetFileName).ToArray();
        Assert.Empty(offenders);
    }

    [Fact]
    public void ARestoreRefusedAfterItsConfirmationIsReported()
    {
        var restore = Method(Source("MainWindowShell.xaml.cs"), "private async void RestoreButton_Click(");
        var confirmed = restore[restore.IndexOf("confirmation.ShowAsync()", StringComparison.Ordinal)..];
        Assert.Contains("throw new InvalidOperationException", confirmed);
        Assert.Contains("\"StopPlayingToRestore\" : \"OperationBusy\"", confirmed);
        Assert.Contains("RestoreViewsFaulted()", restore[..restore.IndexOf("confirmation", StringComparison.Ordinal)]);
        Assert.Contains("\"StopPlayingToRestore\"", Source("UserFacingError.cs"));
    }

    [Fact]
    public void TheRecordingsFactsAreWorkedOutOffTheUiThread()
    {
        var page = Source("ProfilerPage.xaml.cs");
        foreach (var analysis in new[] { "MemoryPressure(", "FramesWithCollector(", "OtherProgramsCpu(" })
            Assert.Single(Regex.Matches(page, @"ProfileAnalysis\." + Regex.Escape(analysis)));
        var load = Method(page, "private async Task LoadAsync(");
        var worker = load[load.IndexOf("await Task.Run(", StringComparison.Ordinal)..];
        Assert.Contains("RecordingFacts.Of(read)", worker[..worker.IndexOf("});", StringComparison.Ordinal)]);
    }

    [Fact]
    public void EveryAnimationTheAppStartsFollowsTheWindowsAnimationSetting()
    {
        var offenders = AppSources()
            .Where(file => File.ReadAllText(file) is var text && text.Contains("StartAnimation(", StringComparison.Ordinal)
                && !text.Contains("SystemMotion.Enabled", StringComparison.Ordinal)
                && !text.Contains("AnimationsEnabled", StringComparison.Ordinal))
            .Select(Path.GetFileName).ToArray();
        Assert.Empty(offenders);
        Assert.Contains("if (animateNewRows && newRows.Count > 0 && SystemMotion.Enabled)", Source("LogsPage.xaml.cs"));
        Assert.Contains("revisionEntranceInProgress = changedSave && motion;", Source("MainWindowShell.xaml.cs"));
    }

    [Fact]
    public void GameExtensionSettingsErrorsGoToTheSidebarCards()
    {
        Assert.DoesNotContain("<InfoBar", Source("GameExtensionsPage.xaml"));
        Assert.Contains("App.ShowSidebarNotification(InfoBarSeverity.Error, Localizer.Get(\"GameExtensions.SettingsError\")",
            Source("GameExtensionsPage.xaml.cs"));
    }

    [Fact]
    public void CopiedLogDetailsNameTheLevelLineByTheColumnNotItsFilter()
    {
        var copy = Method(Source("LogsPage.xaml.cs"), "private void CopyLogDetailsButton_Click(");
        Assert.DoesNotContain("LogLevelHeader.Text", copy);
        Assert.Contains("Localizer.Get(\"LogLevelHeader\")", copy);
    }

    [Fact]
    public void TheOperationCardWritesSizesInTheLanguagesUnits()
    {
        var progress = Method(Source("MainWindowShell.xaml.cs"), "private void ApplyProgress(");
        Assert.DoesNotContain(" MB\"", progress);
        Assert.Contains("Units.Bytes(operation.CompletedBytes", progress);
    }

    private static string Method(string source, string signature)
    {
        var start = source.IndexOf(signature, StringComparison.Ordinal);
        Assert.True(start >= 0, $"Expected {signature}");
        var next = Regex.Match(source[(start + signature.Length)..], @"\n    (private|internal|public) ");
        return next.Success ? source.Substring(start, signature.Length + next.Index) : source[start..];
    }

    private static IEnumerable<string> AppSources() =>
        Directory.EnumerateFiles(AppRoot(), "*.cs", SearchOption.AllDirectories)
            .Where(path => !path.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")
                && !path.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}"));

    private static string Source(string name) => File.ReadAllText(Path.Combine(AppRoot(), name));

    private static string AppRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "PzTools.sln")))
                return Path.Combine(directory.FullName, "src", "PzTools.App");
        throw new DirectoryNotFoundException("Repository source is required for the app's UI contracts.");
    }
}
