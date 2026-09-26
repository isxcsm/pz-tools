using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace PzTools.Backup.Tests;

/// <summary>Source/resource contracts only; these checks do not launch WinUI or claim visual verification.</summary>
public sealed class VehicleDrivingUiSourceTests
{
    [Fact]
    public void ExtensionsUseNativeInlineSectionsAndNoModalOrTechnicalPanel()
    {
        var page = Source("GameExtensionsPage.xaml.cs");
        var section = Source("ExtensionSettingsSection.cs");
        foreach (var source in new[] { page, section })
            foreach (var removed in new[] { "ContentDialog", "ShowAsync", "ConfigureAsync", "dialogOpen",
                "TechnicalDetails", "module_sha256", "new CheckBox", "ProbeOnly", "DiagnosticsEnabled" })
                Assert.DoesNotContain(removed, source);
        Assert.False(File.Exists(Path.Combine(Root(), "src", "PzTools.App", "LightDismissContentDialog.cs")));
        Assert.Contains("new SettingsExpander", section);
        Assert.Contains("new SettingsCard", section);
        Assert.Contains("Control.Items.Add(row.Card)", section);
        Assert.Contains("Content = enabled.Control", section);
        Assert.Contains("Content = editor.Control", section);
        Assert.Equal(3, Regex.Matches(section, @"AddOption\(GameExtensionSetting\.(Torque|Reverse|Steering),").Count);
        Assert.Single(Regex.Matches(section, @"AddOption\(GameExtensionSetting.ForceVersion,").Cast<Match>());
        foreach (var name in new[] { "Torque", "Reverse", "Steering" })
            Assert.Contains($"GameExtensionSetting.{name} => preference.{name}Enabled", section);
    }

    [Fact]
    public void RuntimeAndPreferenceRefreshesReuseControlsWithoutResettingExpansionOrScroll()
    {
        var page = Source("GameExtensionsPage.xaml.cs");
        var section = Source("ExtensionSettingsSection.cs");
        Assert.Contains("Dictionary<string, ExtensionSettingsSection>", page);
        Assert.Contains("ObservableCollection<SettingsExpander> Sections", page);
        Assert.Contains("if (!sections.TryGetValue(id, out var section))", page);
        Assert.Single(Regex.Matches(page, "new ExtensionSettingsSection").Cast<Match>());
        Assert.Contains("section.Update(view, card)", page);
        Assert.Contains("desired.Add(section.Control)", page);
        Assert.Contains("IncrementalListReconciler.Reconcile(Sections, desired)", page);
        Assert.DoesNotContain(".Clear()", page);
        Assert.DoesNotContain("ChangeView", page);
        Assert.DoesNotContain("Focus(", page);
        var update = section[section.IndexOf("public void Update(GameExtensionsView", StringComparison.Ordinal)..];
        Assert.DoesNotContain("IsExpanded =", update);
        Assert.DoesNotContain("new SettingsExpander", update);
        Assert.Contains("if (block.Text != text) block.Text = text", update);
        Assert.Contains("if (block.Visibility != visibility)", update);
    }

    [Fact]
    public void OnlyThePageScrollsAndSpacingMatchesTheExistingSettingsPage()
    {
        XNamespace ns = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";
        var page = XDocument.Load(Path.Combine(Root(), "src", "PzTools.App", "GameExtensionsPage.xaml"));
        var settings = XDocument.Load(Path.Combine(Root(), "src", "PzTools.App", "SettingsPage.xaml"));
        Assert.Single(page.Descendants(ns + "ScrollViewer"));
        Assert.Equal("{x:Bind Sections}", (string?)page.Descendants(ns + "ItemsControl").Single().Attribute("ItemsSource"));
        string Spacing(XDocument document) => document.Descendants().Single(element =>
            (string?)element.Attribute(x + "Key") == "SettingsCardSpacing").Value;
        Assert.Equal(Spacing(settings), Spacing(page));
        Assert.DoesNotContain("new ScrollViewer", Source("ExtensionSettingsSection.cs"));
    }

    [Fact]
    public void RuntimeWaitAndWritesDoNotDisableTheWholePageOrRecreateTheSwitches()
    {
        var page = Source("GameExtensionsPage.xaml.cs");
        var section = Source("ExtensionSettingsSection.cs");
        Assert.DoesNotContain("applying", page);
        Assert.DoesNotContain("IsEnabled = false", page + section);
        Assert.DoesNotContain("new ProgressRing", page + section);
        Assert.Contains("GameExtensions.ApplyWhenSafe", section);
        Assert.Contains("row.Update(value, activation.CanEditOptions)", section);
        Assert.Contains("enabled.Update(activation.IsOn, activation.CanToggle, name)", section);
        Assert.DoesNotContain("AppliedVehicleOptions", section);
        Assert.Contains("ToggleSwitch Control { get; } = new()", section);
        Assert.DoesNotContain("Control.Header", section);
    }

    [Fact]
    public void PendingEditsKeepUserIntentAndProgrammaticReflectionCannotWriteAgain()
    {
        var section = Source("ExtensionSettingsSection.cs");
        Assert.Contains("if (reflecting) return", section);
        Assert.Contains("var requested = Control.IsOn", section);
        Assert.Contains("pendingWrites++", section);
        Assert.Contains("await save(requested)", section);
        Assert.Contains("finally { pendingWrites--; ReflectSavedValue(); }", section);
        Assert.Contains("savedValue = value", section);
        Assert.Contains("if (pendingWrites != 0 || Control.IsOn == savedValue) return", section);
        Assert.Contains("reflecting = true", section);
        Assert.Contains("finally { reflecting = false; }", section);
    }

    [Fact]
    public void AllFiveEditsUseTheControllerQueueAndReadTheLatestRevisionedView()
    {
        var page = Source("GameExtensionsPage.xaml.cs");
        var section = Source("ExtensionSettingsSection.cs");
        Assert.Single(Regex.Matches(page, @"await host.GameExtensions.ApplyEditAsync\(").Cast<Match>());
        Assert.Contains("SaveEditAsync(id, setting, value)", page);
        Assert.Contains("save(GameExtensionSetting.Enabled, value)", section);
        Assert.Contains("value => save(setting, value)", section);
        Assert.DoesNotContain("SetPreferenceAsync", page);
        Assert.DoesNotContain("SetVehicleDrivetrainPreferenceAsync", page);
        Assert.DoesNotContain("UpdateView(await", page);
        Assert.DoesNotContain("snapshot = await", page);
        Assert.Contains("viewRevision = changed.ViewRevision", page);
        Assert.Contains("UpdateView(view)", page);
        Assert.Contains("finally\n        {\n            // Read the revisioned store", page.Replace("\r\n", "\n"));
    }

    [Fact]
    public void AllEighteenLanguagesTranslateTheThreeFeaturesAndRemoveOldOptionKeys()
    {
        var files = Directory.GetFiles(Path.Combine(Root(), "src", "PzTools.App", "Strings"), "Resources.resw", SearchOption.AllDirectories);
        Assert.Equal(18, files.Length);
        string[] features = ["VehicleDrivetrain.Torque", "VehicleDrivetrain.Reverse", "VehicleDrivetrain.Steering"];
        var english = Read(files.Single(path => Path.GetFileName(Path.GetDirectoryName(path)) == "en-US"));
        foreach (var file in files)
        {
            var resources = Read(file);
            Assert.Equal(3, features.Select(key => resources[key]).Distinct().Count());
            foreach (var key in features)
            {
                Assert.False(string.IsNullOrWhiteSpace(resources[key]));
                Assert.False(string.IsNullOrWhiteSpace(resources[key + "Description"]));
                if (Path.GetFileName(Path.GetDirectoryName(file)) != "en-US") Assert.NotEqual(english[key], resources[key]);
            }
            foreach (var key in new[] { "VehicleDrivetrain.LowMode", "VehicleDrivetrain.ProbeOnly", "VehicleDrivetrain.Diagnostics", "VehicleDrivetrain.Observing" })
                Assert.False(resources.ContainsKey(key), file + ": obsolete option " + key);
        }
    }

    private static string Source(string name) => File.ReadAllText(Path.Combine(Root(), "src", "PzTools.App", name));
    private static Dictionary<string, string> Read(string path) => XDocument.Load(path).Root!.Elements("data")
        .ToDictionary(item => item.Attribute("name")!.Value, item => item.Element("value")!.Value);

    private static string Root()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "PzTools.sln"))) return directory.FullName;
        throw new DirectoryNotFoundException("Repository source is required for UI source contracts.");
    }
}
