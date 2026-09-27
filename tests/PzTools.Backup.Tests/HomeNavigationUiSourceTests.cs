using System.Xml.Linq;
using System.Text.RegularExpressions;

namespace PzTools.Backup.Tests;

/// <summary>Startup source contracts; the full navigation shell is not launched by these tests.</summary>
public sealed class HomeNavigationUiSourceTests
{
    private static readonly XNamespace Names = "http://schemas.microsoft.com/winfx/2006/xaml";

    [Fact]
    public void HomeResourceReferencesExistBeforeThePageIsConstructed()
    {
        var resources = XDocument.Parse(Source("Strings/en-US/Resources.resw")).Root!
            .Elements("data").Select(item => (string)item.Attribute("name")!).ToHashSet();
        var calls = Regex.Matches(Source("HomePage.xaml.cs"), "Localizer\\.Get\\(\"([^\"]+)\"\\)");
        Assert.NotEmpty(calls);
        foreach (Match call in calls)
            Assert.Contains(call.Groups[1].Value, resources);
    }

    [Fact]
    public void HomeAndNavigationParticipateInLiveLanguageChanges()
    {
        var page = XDocument.Parse(Source("HomePage.xaml"));
        Assert.Null(page.Root!.Attribute("Language"));
        Assert.Empty(page.Descendants(Names + "String"));
        var shell = XDocument.Parse(Source("MainWindowShell.xaml"));
        Assert.Null(Named(shell, "HomeItem").Attribute("Language"));
        Assert.Null(Named(shell, "HomeItem").Attribute("Content"));
        var source = Source("MainWindowShell.xaml.cs");
        Assert.Contains("HomeItem.Content = Localizer.Get(\"HomeNavigation.Content\");", source);
        var refreshStart = source.IndexOf("internal void RefreshLocalization()", StringComparison.Ordinal);
        var refreshEnd = source.IndexOf("private void ", refreshStart, StringComparison.Ordinal);
        Assert.Contains("HomeRoot.ApplyLocalizedText();", source[refreshStart..refreshEnd]);
        var home = Source("HomePage.xaml.cs");
        Assert.Contains("Language = Localizer.Culture.Name;", home);
        Assert.Contains("InitializeComponent();\n        ApplyLocalizedText();", home.Replace("\r\n", "\n"));
    }

    [Fact]
    public void FirstFrameShowsHomeAndKeepsSavesRealizedWithoutAcceptingInput()
    {
        var shell = XDocument.Parse(Source("MainWindowShell.xaml"));
        var home = Named(shell, "HomeRoot");
        Assert.Equal("Visible", (string?)home.Attribute("Visibility") ?? "Visible");
        var saves = Named(shell, "SavesRoot");
        Assert.Equal("Visible", (string?)saves.Attribute("Visibility") ?? "Visible");
        Assert.Equal("0", (string?)saves.Attribute("Opacity"));
        Assert.Equal("False", (string?)saves.Attribute("IsHitTestVisible"));
    }

    [Fact]
    public void FirstLoadSelectsHomeAndMovesPointerFocusOffThePaneToggle()
    {
        var source = Source("MainWindowShell.xaml.cs");
        var start = source.IndexOf("private void OnLoaded(", StringComparison.Ordinal);
        var end = source.IndexOf("private void ", start + 1, StringComparison.Ordinal);
        Assert.True(start >= 0 && end > start, "Expected an isolated OnLoaded method.");
        var loaded = source[start..end];
        Assert.Contains("Navigation.SelectedItem ??= HomeItem;", loaded);
        Assert.Contains("if (!hasSetInitialFocus)", loaded);
        Assert.Contains("hasSetInitialFocus = HomeItem.Focus(FocusState.Pointer);", loaded);
        Assert.DoesNotContain("SavesItem.Focus(", loaded);
    }

    private static XElement Named(XDocument document, string name) => document.Descendants()
        .Single(element => (string?)element.Attribute(Names + "Name") == name);

    private static string Source(string name)
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "PzTools.sln")))
                return File.ReadAllText(Path.Combine(directory.FullName, "src", "PzTools.App", name));
        throw new DirectoryNotFoundException("Repository source is required for Home startup contracts.");
    }
}
