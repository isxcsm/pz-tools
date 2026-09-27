using System.Xml.Linq;

namespace PzTools.Backup.Tests;

/// <summary>Source contracts; native pointer/focus rendering remains a user E2E check.</summary>
public sealed class CoffeeSupportUiSourceTests
{
    private static readonly XNamespace Xaml = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
    private static readonly XNamespace Names = "http://schemas.microsoft.com/winfx/2006/xaml";

    [Fact]
    public void NativeLinkUsesTransparentBackgroundAndAOneLineNeutralLabel()
    {
        var shell = XDocument.Parse(Source("MainWindowShell.xaml"));
        var button = shell.Descendants(Xaml + "HyperlinkButton").Single(element =>
            (string?)element.Attribute(Names + "Name") == "CoffeeSupportButton");
        Assert.Equal("Transparent", (string?)button.Attribute("Background"));
        Assert.Equal("{ThemeResource TextFillColorSecondaryBrush}", (string?)button.Attribute("Foreground"));
        Assert.Null(button.Attribute("Style"));
        Assert.Empty(button.Elements(Xaml + "HyperlinkButton.Template"));
        Assert.NotEqual("False", (string?)button.Attribute("UseSystemFocusVisuals"));
        var title = button.Descendants(Xaml + "TextBlock").Single();
        Assert.Equal("CoffeeSupportTitle", (string?)title.Attribute(Names + "Name"));
        Assert.Equal("NoWrap", (string?)title.Attribute("TextWrapping"));
        Assert.Equal("{ThemeResource TextFillColorPrimaryBrush}", (string?)title.Attribute("Foreground"));
        var icon = button.Descendants(Xaml + "PathIcon").Single();
        Assert.Null(icon.Attribute("Foreground")); // Inherit native CommonStates, unlike the label.
        Assert.Equal("24", (string?)icon.Attribute("Width"));
        Assert.Equal("24", (string?)icon.Attribute("Height"));
        Assert.StartsWith("F1 M", (string?)icon.Attribute("Data"));
        Assert.Null(title.Parent!.Attribute("ColumnSpacing")); // No empty gap after the label collapses.
        Assert.Equal("10,0,0,0", (string?)title.Attribute("Margin"));
        Assert.Contains("CoffeeSupportTitle.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;",
            Source("MainWindowShell.xaml.cs"));
    }

    [Theory]
    [InlineData("Default", "#FFDD00")]
    [InlineData("HighContrast", "{ThemeResource SystemColorWindowTextColor}")]
    public void OnlyHoverAndPressedIconColorUseTheBrandAccent(string theme, string color)
    {
        var shell = XDocument.Parse(Source("MainWindowShell.xaml"));
        var button = shell.Descendants(Xaml + "HyperlinkButton").Single(element =>
            (string?)element.Attribute(Names + "Name") == "CoffeeSupportButton");
        var dictionary = button.Descendants(Xaml + "ResourceDictionary").Single(element =>
            (string?)element.Attribute(Names + "Key") == theme);
        Assert.Equal(2, dictionary.Elements().Count());
        foreach (var state in new[] { "PointerOver", "Pressed" })
            Assert.Equal(color, (string?)dictionary.Elements(Xaml + "SolidColorBrush").Single(element =>
                (string?)element.Attribute(Names + "Key") == "HyperlinkButtonForeground" + state).Attribute("Color"));
    }

    [Fact]
    public void SupportDestinationAndAccessibleLabelRemainWithoutTooltips()
    {
        var source = Source("MainWindowShell.Support.cs");
        Assert.Contains("https://buymeacoffee.com/iou3019", source);
        Assert.Contains("CoffeeSupportButton.NavigateUri = SupportPage;", source);
        Assert.Contains("var label = CoffeeSupportTitle.Text;", source);
        Assert.Contains("AutomationProperties.SetName(CoffeeSupportButton, label);", source);
        Assert.DoesNotContain("ToolTip", source);
        Assert.DoesNotContain("CoffeeSupportMessage", Source("MainWindowShell.xaml"));
    }

    private static string Source(string name)
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "PzTools.sln")))
                return File.ReadAllText(Path.Combine(directory.FullName, "src", "PzTools.App", name));
        throw new DirectoryNotFoundException("Repository source is required for support button contracts.");
    }
}
