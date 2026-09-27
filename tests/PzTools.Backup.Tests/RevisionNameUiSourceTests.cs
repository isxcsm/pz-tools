using System.Xml.Linq;

namespace PzTools.Backup.Tests;

/// <summary>Template contracts only; actual glyph baselines and IME behavior require user E2E.</summary>
public sealed class RevisionNameUiSourceTests
{
    private static readonly XNamespace Xaml = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
    private static readonly XNamespace Names = "http://schemas.microsoft.com/winfx/2006/xaml";

    [Fact]
    public void EditorAndPlaceholderUseOneCenteredTextHostAndTheSameInsets()
    {
        var style = EditorStyle();
        var content = style.Descendants(Xaml + "ScrollViewer").Single();
        var placeholder = style.Descendants(Xaml + "TextBlock").Single();
        Assert.Same(content.Parent, placeholder.Parent);
        Assert.Equal("Grid", content.Parent!.Name.LocalName);
        Assert.Equal("Center", (string?)content.Parent.Attribute("VerticalAlignment"));
        Assert.Null(content.Attribute("VerticalAlignment"));
        Assert.Null(placeholder.Attribute("VerticalAlignment"));
        Assert.Equal("Top", (string?)content.Attribute("VerticalContentAlignment"));
        Assert.Equal("{TemplateBinding Padding}", (string?)content.Attribute("Padding"));
        Assert.Equal((string?)content.Attribute("Padding"), (string?)placeholder.Attribute("Padding"));
        Assert.Equal("ContentElement", (string?)content.Attribute(Names + "Name"));
        Assert.Equal("PlaceholderTextContentPresenter", (string?)placeholder.Attribute(Names + "Name"));
        foreach (var property in new[] { "FontFamily", "FontSize", "FontWeight", "TextAlignment" })
            Assert.Equal($"{{TemplateBinding {property}}}", (string?)placeholder.Attribute(property));
        Assert.DoesNotContain(style.Descendants(), element => element.Name.LocalName.Contains("Transform", StringComparison.Ordinal));
    }

    [Fact]
    public void DisplayAndEditKeepTypographyAndTheirSharedRowAlignment()
    {
        var style = EditorStyle();
        var setters = style.Elements(Xaml + "Setter").ToDictionary(element => (string)element.Attribute("Property")!);
        var shell = Read("MainWindowShell.xaml");
        var editor = shell.Descendants(Xaml + "TextBox").Single(element =>
            (string?)element.Attribute("Style") == "{StaticResource InlineRevisionNameTextBoxStyle}");
        var display = editor.Parent!.Elements(Xaml + "TextBlock").Single();
        foreach (var property in new[] { "FontSize", "FontWeight" })
            Assert.Equal((string?)setters[property].Attribute("Value"), (string?)display.Attribute(property));
        Assert.Equal("{StaticResource DefaultTextBoxStyle}", (string?)style.Attribute("BasedOn"));
        Assert.Equal("{ThemeResource ContentControlThemeFontFamily}", (string?)display.Attribute("FontFamily"));
        Assert.Equal("Center", (string?)display.Attribute("VerticalAlignment"));
        Assert.Equal("Center", (string?)editor.Attribute("VerticalAlignment"));
        Assert.Equal("0", (string?)setters["Padding"].Attribute("Value"));
        Assert.Equal("0", (string?)setters["BorderThickness"].Attribute("Value"));
    }

    private static XElement EditorStyle() => Read("App.xaml").Descendants(Xaml + "Style").Single(element =>
        (string?)element.Attribute(Names + "Key") == "InlineRevisionNameTextBoxStyle");

    private static XDocument Read(string name)
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "PzTools.sln")))
                return XDocument.Load(Path.Combine(directory.FullName, "src", "PzTools.App", name));
        throw new DirectoryNotFoundException("Repository source is required for UI template contracts.");
    }
}
