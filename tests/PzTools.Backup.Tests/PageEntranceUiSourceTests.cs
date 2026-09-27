using System.Xml.Linq;

namespace PzTools.Backup.Tests;

/// <summary>Source contracts for transition ordering, not a WinUI rendering test.</summary>
public sealed class PageEntranceUiSourceTests
{
    [Fact]
    public void PageSwapDoesNotRestoreVisibilityBeforeIncomingLayoutIsPrepared()
    {
        var source = Source("MainWindowShell.Navigation.cs");
        Assert.Contains("PageContent.Opacity = entering ? 1 : 0;", source);
        Assert.Contains("ResetContentTransition(restorePresentation: !contentExiting);", source);
        var present = source[source.IndexOf("private void PresentContent", StringComparison.Ordinal)..
            source.IndexOf("private void AnimateContent", StringComparison.Ordinal)];
        Assert.True(present.IndexOf("SettingsRoot.PrepareForNavigation()", StringComparison.Ordinal)
            < present.IndexOf("SettingsRoot.Visibility =", StringComparison.Ordinal));
        Assert.True(present.IndexOf("SettingsRoot.Visibility =", StringComparison.Ordinal)
            < present.IndexOf("SettingsRoot.CompleteInitialLayout()", StringComparison.Ordinal));
        Assert.Contains("if (!ReferenceEquals(sender, contentTransitionBatch)) return;", source);
        Assert.Contains("if (contentExiting) return;", source);
        Assert.Contains("!navigationUiSettings.AnimationsEnabled", source);
    }

    [Fact]
    public void SettingsInitialExpansionSettlesBeforeReflowTransitionsAreAttached()
    {
        XNamespace ns = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
        XNamespace names = "http://schemas.microsoft.com/winfx/2006/xaml";
        var xaml = XDocument.Parse(Source("SettingsPage.xaml"));
        var sections = xaml.Descendants(ns + "StackPanel").Single(element =>
            (string?)element.Attribute(names + "Name") == "SettingsSections");
        Assert.Empty(sections.Elements(ns + "StackPanel.ChildrenTransitions"));
        var source = Source("SettingsPage.xaml.cs");
        Assert.Contains("if (!settingsLoaded || !initialLayoutCompleted) LoadSettings();", source);
        var layout = source[source.IndexOf("internal void CompleteInitialLayout", StringComparison.Ordinal)..
            source.IndexOf("private void LoadSettings", StringComparison.Ordinal)];
        Assert.Contains("if (initialLayoutCompleted) return;", layout);
        Assert.Contains("group.Name == \"ExpandStates\"", layout);
        Assert.Contains("storyboard.GetCurrentState() == ClockState.Active", layout);
        Assert.True(layout.IndexOf("storyboard.SkipToFill()", StringComparison.Ordinal)
            < layout.IndexOf("SettingsSections.ChildrenTransitions =", StringComparison.Ordinal));
        Assert.Contains("new RepositionThemeTransition { IsStaggeringEnabled = false }", layout);
        Assert.DoesNotContain("Task.Delay", layout);
    }

    private static string Source(string name)
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "PzTools.sln")))
                return File.ReadAllText(Path.Combine(directory.FullName, "src", "PzTools.App", name));
        throw new DirectoryNotFoundException("Repository source is required for UI transition contracts.");
    }
}
