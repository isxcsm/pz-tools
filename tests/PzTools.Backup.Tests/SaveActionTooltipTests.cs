using System.Xml.Linq;

namespace PzTools.Backup.Tests;

public sealed class SaveActionTooltipTests
{
    [Theory]
    [InlineData("RestoreButton_Click", "RestoreToolTipHost")]
    [InlineData("ExportButton_Click", "ExportToolTipHost")]
    [InlineData("DeleteSave_Click", null)]
    [InlineData("HealCharacter_Click", null)]
    public void DisabledActionsKeepAnEnabledHoverTarget(string clickHandler, string? hostName)
    {
        var xaml = XDocument.Load(Path.Combine(AppSource(), "MainWindowShell.xaml"));
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";
        XNamespace local = "using:PzTools.App";
        var button = Assert.Single(xaml.Descendants(), e => (string?)e.Attribute("Click") == clickHandler);
        var host = button.Parent!;
        Assert.Equal("Border", host.Name.LocalName);
        Assert.Equal("Transparent", (string?)host.Attribute("Background"));
        Assert.Null(host.Attribute("IsEnabled"));
        Assert.Null(host.Attribute("IsHitTestVisible"));
        Assert.Null(button.Attribute("ToolTipService.ToolTip"));
        Assert.NotNull(button.Attribute("IsEnabled"));
        if (hostName is not null) Assert.Equal(hostName, (string?)host.Attribute(x + "Name"));
        else
        {
            Assert.Contains("Mode=OneWay", (string?)host.Attribute(local + "AppToolTip.Tip"));
            Assert.NotNull(button.Attribute("AutomationProperties.HelpText"));
        }
    }

    [Fact]
    public void ActionRefreshUsesStableTooltipsInsteadOfReregisteringThem()
    {
        var source = File.ReadAllText(Path.Combine(AppSource(), "MainWindowShell.xaml.cs"));
        var start = source.IndexOf("private void UpdateRevisionActions()", StringComparison.Ordinal);
        var end = source.IndexOf("private async void DeleteSave_Click", start, StringComparison.Ordinal);
        var refresh = source[start..end];
        Assert.DoesNotContain("ToolTipService.SetToolTip", refresh);
        foreach (var owner in new[] { "RestoreToolTipHost", "ExportToolTipHost", "DeleteAllBackupsButton" })
            Assert.Contains($"AppToolTip.SetTip({owner},", refresh);
    }

    [Fact]
    public void AllAppTooltipsUseTheImmediatePresenterWithoutTheNativeHoverTimer()
    {
        foreach (var path in Directory.EnumerateFiles(AppSource(), "*.xaml"))
            Assert.DoesNotContain("ToolTipService.ToolTip", File.ReadAllText(path));
        foreach (var path in Directory.EnumerateFiles(AppSource(), "*.cs").Where(path => Path.GetFileName(path) != "AppToolTip.cs"))
            Assert.DoesNotContain("ToolTipService.SetToolTip", File.ReadAllText(path));
        var presenter = File.ReadAllText(Path.Combine(AppSource(), "AppToolTip.cs"));
        Assert.Contains("owner.PointerEntered += OnEntered", presenter);
        Assert.Contains("tooltip.IsOpen = true", presenter);
        Assert.Contains("ToolTipService.SetToolTip(owner, tooltip)", presenter);
        Assert.DoesNotContain("Task.Delay", presenter);
        Assert.DoesNotContain("DispatcherQueueTimer", presenter);
    }

    [Theory]
    [InlineData("ko-KR")]
    [InlineData("en-US")]
    public void AllPlayRestrictionsHaveLocalizedExplanations(string language)
    {
        var resources = XDocument.Load(Path.Combine(AppSource(), "Strings", language, "Resources.resw"));
        foreach (var key in new[] { "StopPlayingToExport", "StopPlayingToRestore", "StopPlayingToDeleteSave", "StopPlayingToHeal" })
        {
            var entry = Assert.Single(resources.Root!.Elements("data"), e => (string?)e.Attribute("name") == key);
            Assert.False(string.IsNullOrWhiteSpace(entry.Element("value")?.Value));
        }
    }

    private static string AppSource()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !File.Exists(Path.Combine(root.FullName, "PzTools.sln"))) root = root.Parent;
        Assert.NotNull(root);
        return Path.Combine(root.FullName, "src", "PzTools.App");
    }
}
