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
        Assert.Contains("IsExpanded = initiallyExpanded", section);
        Assert.Contains("new SettingsCard", section);
        Assert.Contains("Control.Items.Add(row.Card)", section);
        Assert.Contains("Content = enabled.Control", section);
        Assert.Contains("Content = editor.Control", section);
        // The extension's own switches come from its descriptor, in its order, before the status card.
        Assert.Contains("foreach (var option in descriptor.Options) AddOption(option.Key, option.TitleKey, option.DescriptionKey, option);", section);
        Assert.True(section.IndexOf("foreach (var option in descriptor.Options)", StringComparison.Ordinal)
            < section.IndexOf("Control.Items.Add(new SettingsCard { Header = statusTitle", StringComparison.Ordinal));
        Assert.Single(Regex.Matches(section, @"AddOption\(GameExtensionSetting.ForceVersion,").Cast<Match>());
        Assert.Contains("row.Update(row.Option is { } option ? card.Option(option) : card.ForceVersion)", section);
        Assert.Contains("Glyph = descriptor.Glyph", section);
    }

    [Fact]
    public void TheVehicleSectionKeepsItsRowsTextsGlyphAndOrder()
    {
        var vehicle = PzTools.GameExtensions.ExtensionDescriptors.For(PzTools.GameExtensions.VehicleDrivetrainExtension.Id);
        Assert.Equal("\uE804", vehicle.Glyph);
        Assert.Equal(["Torque", "Reverse", "Steering", "AreaLight"], vehicle.Options.Select(option => option.TitleKey["VehicleDrivetrain.".Length..]));
        Assert.All(vehicle.Options, option =>
        {
            Assert.Equal(option.TitleKey + "Description", option.DescriptionKey);
            Assert.True(option.Default);
        });
        Assert.Equal(["torqueEnabled", "reverseEnabled", "steeringEnabled", "areaLightEnabled"], vehicle.Options.Select(option => option.Key));
        Assert.Equal("GameExtensions.ApplyWhenSafe", vehicle.SafeBoundaryHintKey);
        // No switch takes the name of the main switch or of the version override.
        Assert.All(PzTools.GameExtensions.ExtensionDescriptors.All.SelectMany(descriptor => descriptor.Options), option =>
            Assert.DoesNotContain(option.Key, new[] { PzTools.App.Core.GameExtensionSetting.Enabled, PzTools.App.Core.GameExtensionSetting.ForceVersion }));
        // An extension without a descriptor: no switches of its own, the general glyph and hint.
        var other = PzTools.GameExtensions.ExtensionDescriptors.For("pztools.another-extension");
        Assert.Empty(other.Options);
        Assert.Equal("\uEA86", other.Glyph);
        Assert.Equal("GameExtensions.Applying", other.SafeBoundaryHintKey);
    }

    /// <summary>The generic layers know no extension by name: what is particular to one lives in its own files.</summary>
    [Fact]
    public void NoGenericLayerNamesTheVehicle()
    {
        foreach (var file in new[]
        {
            "PzTools.Process.Contracts/GameRuntime/RuntimeExtensionStatus.cs", "PzTools.Process.Hosting/RuntimeExtensionStatusStore.cs",
            "PzTools.GameExtensions/ExtensionSettingsStore.cs", "PzTools.GameExtensions/ExtensionModels.cs",
            "PzTools.GameExtensions/ExtensionCatalog.cs", "PzTools.GameExtensions/ContinuousConfiguration.cs",
            "PzTools.GameExtensions/GameVersionSupport.cs", "PzTools.GameBridge/GameExtensionActivationState.cs",
            "PzTools.GameBridge/GameExtensionReconciler.cs", "PzTools.GameBridge/GameExtensionClient.cs",
            "PzTools.State.Scheduler/RuntimeExtensionCoordinator.cs", "PzTools.App.Core/ExtensionActivationView.cs",
            "PzTools.App.Core/GameExtensionController.cs", "PzTools.App.Core/GameExtensionSetting.cs",
            "PzTools.App.Core/ExtensionRuntimeDiagnostics.cs", "PzTools.App/ExtensionSettingsSection.cs", "PzTools.App/GameExtensionsPage.xaml.cs",
        })
            Assert.DoesNotMatch("(?i)vehicle|drivetrain|torque|steering", File.ReadAllText(Path.Combine(Root(), "src", file)));
        // The capabilities name the vehicle's first capability only as the alias of the continuous one; the registry
        // only registers its descriptor.
        var capabilities = File.ReadAllText(Path.Combine(Root(), "src", "PzTools.GameExtensions", "ExtensionCapabilities.cs"));
        Assert.Single(Regex.Matches(capabilities, "(?i)vehicle").Cast<Match>());
        Assert.Contains("LegacyContinuous = \"vehicle.drivetrain.v1\"", capabilities);
        var registry = File.ReadAllText(Path.Combine(Root(), "src", "PzTools.GameExtensions", "ExtensionDescriptor.cs"));
        Assert.Single(Regex.Matches(registry, "(?i)vehicle").Cast<Match>());
    }

    [Fact]
    public void RuntimeAndPreferenceRefreshesReuseControlsWithoutResettingExpansionOrScroll()
    {
        var page = Source("GameExtensionsPage.xaml.cs");
        var section = Source("ExtensionSettingsSection.cs");
        Assert.Contains("Dictionary<string, ExtensionSettingsSection>", page);
        Assert.Contains("ObservableCollection<SettingsExpander> Sections", page);
        Assert.Contains("if (!sections.TryGetValue(id, out var section))", page);
        Assert.Contains("initiallyExpanded: view.Cards.Count == 1", page);
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
        Assert.Contains("Control.Loaded -= CompleteInitialLayout;", section);
        Assert.Contains("SettingsExpanderLayout.CompleteInitialExpansion(Control);", section);
        Assert.DoesNotContain("SettingsExpanderLayout", update);
    }

    [Fact]
    public void ExtensionHeaderStaysBriefWhileBodyKeepsCompatibilityAndRuntimeHints()
    {
        var section = Source("ExtensionSettingsSection.cs");
        Assert.Contains("Header = title, Description = description, Content = enabled.Control", section);
        Assert.Contains("new[] { version, hint }", section);
        Assert.Contains("Control.Items.Add(new SettingsCard { Header = statusTitle, Description = details })", section);
        Assert.Contains("GameExtensions.CompatibilityStatus", section);
        foreach (var key in new[] { "VersionInfo", "InitializationFailed", "Applying",
            "WorldRequired", "VersionMismatch", "VersionUnknown", "ForceWarning" })
            Assert.Contains("GameExtensions." + key, section);
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
        Assert.Contains("descriptor.SafeBoundaryHintKey", section);
        Assert.Contains("row.Update(row.Option is { } option ? card.Option(option) : card.ForceVersion)", section);
        Assert.Contains("enabled.Update(activation.IsOn, activation.CanToggle, name)", section);
        Assert.DoesNotContain("AppliedConfiguration", section);
        Assert.Contains("ToggleSwitch Control { get; } = new()", section);
        Assert.DoesNotContain("Control.Header", section);
    }

    [Fact]
    public void AGameRejectionForTheVersionShowsTheVersionHintBeforeTheGenericFailure()
    {
        var section = Source("ExtensionSettingsSection.cs");
        int version = section.IndexOf("activation.FailureReason == \"version-mismatch\"", StringComparison.Ordinal);
        int generic = section.IndexOf("GameExtensions.InitializationFailed", StringComparison.Ordinal);
        Assert.True(version >= 0 && version < generic);
    }

    [Fact]
    public void AnUpdateWaitingForTheGamesRestartAsksForTheRestartInsteadOfReportingAFailure()
    {
        var section = Source("ExtensionSettingsSection.cs");
        int restart = section.IndexOf("if (activation.AwaitsGameRestart) return Localizer.Get(\"GameLinkCardRestartMessage\")", StringComparison.Ordinal);
        int generic = section.IndexOf("GameExtensions.InitializationFailed", StringComparison.Ordinal);
        Assert.True(restart >= 0 && restart < generic);
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
    public void AllEighteenLanguagesTranslateEveryFeatureAndRemoveOldOptionKeys()
    {
        var files = Directory.GetFiles(Path.Combine(Root(), "src", "PzTools.App", "Strings"), "Resources.resw", SearchOption.AllDirectories);
        Assert.Equal(18, files.Length);
        string[] features = ["VehicleDrivetrain.Torque", "VehicleDrivetrain.Reverse", "VehicleDrivetrain.Steering", "VehicleDrivetrain.AreaLight"];
        var english = Read(files.Single(path => Path.GetFileName(Path.GetDirectoryName(path)) == "en-US"));
        foreach (var file in files)
        {
            var resources = Read(file);
            Assert.Equal(features.Length, features.Select(key => resources[key]).Distinct().Count());
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
