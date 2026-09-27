using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using PzTools.App;
using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using Windows.Graphics;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace PzTools.ExtensionsSmoke;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        var output = Path.GetFullPath(args.Single());
        Directory.CreateDirectory(output);
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(parameters =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new SmokeApp(output);
        });
    }
}

internal sealed class SmokeApp(string outputDirectory) : Application, IXamlMetadataProvider
{
    private IXamlMetadataProvider? metadata;
    private IXamlMetadataProvider Metadata => metadata ??= (IXamlMetadataProvider)Activator.CreateInstance(
        typeof(SmokeApp).Assembly.GetType("PzTools.ExtensionsSmoke.PzTools_ExtensionsSmoke_XamlTypeInfo.XamlMetaDataProvider", throwOnError: true)!)!;
    public IXamlType GetXamlType(Type type) => Metadata.GetXamlType(type);
    public IXamlType GetXamlType(string fullName) => Metadata.GetXamlType(fullName);
    public XmlnsDefinition[] GetXmlnsDefinitions() => Metadata.GetXmlnsDefinitions();

    private Window? window;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        UnhandledException += (_, error) =>
        {
            Fail(error.Exception);
            error.Handled = true;
            window?.Close();
            Exit();
        };
        try
        {
            Resources.MergedDictionaries.Add(new XamlControlsResources());
            Localizer.SetLanguage(SupportedLanguage.Korean);
            var host = new SmokeHost();
            window = new Window { Content = host };
            var started = false;
            host.Loaded += async (_, _) =>
            {
                if (started) return;
                started = true;
                window.AppWindow.Hide();
                try
                {
                    await RunAsync(host);
                    File.WriteAllText(Path.Combine(outputDirectory, "result.txt"),
                        "PASS: 4 viewport/theme renders, 5 isolated toggle callbacks, initial expansion settled, user animation preserved, collapse persistence, stable controls, runtime/compatibility/guard hints; no AppHost, game or user data access.");
                }
                catch (Exception error) { Fail(error); }
                finally { window.Close(); Exit(); }
            };
            window.Activate();
        }
        catch (Exception error) { Fail(error); window?.Close(); Exit(); }
    }

    private async Task RunAsync(Grid host)
    {
        var definition = ExtensionCatalog.BuiltIn.Single(item => item.Id == ExtensionIds.VehicleDrivetrain);
        var original = new ExtensionCardView(definition, false, "version-unknown", 0, VersionMatches: false);
        foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
        foreach (var width in new[] { 1040, 560 })
        {
            host.RequestedTheme = theme;
            host.Width = width;
            host.Children.Clear();
            var writes = new List<(GameExtensionSetting Setting, bool Value)>();
            var section = new ExtensionSettingsSection(definition.Id, (setting, value) =>
            {
                writes.Add((setting, value));
                return Task.CompletedTask;
            }, initiallyExpanded: true);
            section.Update(new([original], true), original);
            var page = new StackPanel { Spacing = 16, Margin = new Thickness(24) };
            page.Children.Add(new TextBlock { Text = Localizer.Get("GameExtensions.Title"), FontSize = 28 });
            page.Children.Add(section.Control);
            var scroll = new ScrollViewer { Content = page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            host.Children.Add(scroll);
            var scale = host.XamlRoot.RasterizationScale;
            window!.AppWindow.Resize(new SizeInt32((int)(width * scale) + 32, (int)(720 * scale) + 64));
            await SettleAsync(host);
            var expander = (Expander)VisualTreeHelper.GetChild(section.Control, 0);
            var templateRoot = (FrameworkElement)VisualTreeHelper.GetChild(expander, 0);
            var expansion = VisualStateManager.GetVisualStateGroups(templateRoot).Single(group => group.Name == "ExpandStates");
            Check(expansion.CurrentState?.Storyboard?.GetCurrentState() != ClockState.Active,
                "Initial expansion animation still clips option content.");
            Check(section.Control.IsExpanded, "Single extension was not initially expanded.");
            Check(section.Control.Description is TextBlock description && description.Text == Localizer.Get(definition.DescriptionKey),
                "Header description must contain only the extension summary.");
            Check(section.Control.Items.Count == 5, "Three options, status row and version guard are required.");
            var statusCard = (SettingsCard)section.Control.Items[3];
            var details = (StackPanel)statusCard.Description;
            Check(details.Children.OfType<TextBlock>().Any(text => text.Text == Localizer.Get("GameExtensions.VersionUnknown")),
                "Version admission reason was lost.");
            Check(((TextBlock)((SettingsCard)section.Control.Items[4]).Description).Text == Localizer.Get("GameExtensions.ForceWarning"),
                "Version guard warning was lost.");
            var texts = Descendants(page).OfType<TextBlock>().Where(text => text.Visibility == Visibility.Visible).ToArray();
            Check(!texts.Any(text => text.IsTextTrimmed), "Extension text was clipped.");
            var stem = "extensions-" + (width > 600 ? "wide" : "narrow") + "-" + theme.ToString().ToLowerInvariant();
            // Layout stability was checked above; the native chevron has a separate animation.
            await Task.Delay(500);
            await SavePngAsync(host, stem + ".png", width, 720);
            if (scroll.ScrollableHeight > 0)
            {
                scroll.ChangeView(null, scroll.ScrollableHeight, null, disableAnimation: true);
                await SettleAsync(host);
                await SavePngAsync(host, stem + "-bottom.png", width, 720);
            }
            var master = (ToggleSwitch)section.Control.Content;
            var optionSwitches = section.Control.Items.OfType<SettingsCard>()
                .Where(card => card.Content is ToggleSwitch).Select(card => (ToggleSwitch)card.Content).ToArray();
            Check(optionSwitches.Length == 4, "Expected four option switches.");
            Check(!master.IsOn && optionSwitches.Take(3).All(toggle => toggle.IsOn) && !optionSwitches[3].IsOn,
                "Initial preference values changed.");
            if (width == 1040 && theme == ElementTheme.Light)
            {
                foreach (var toggle in new[] { master }.Concat(optionSwitches))
                {
                    Check(!string.IsNullOrWhiteSpace(AutomationProperties.GetName(toggle)), "A switch has no accessible name.");
                    toggle.IsOn = !toggle.IsOn;
                }
                Check(writes.Select(write => write.Setting).Distinct().Count() == 5 && writes.Count == 5,
                    "Programmatic reflection or toggles issued extra writes.");
            }
            section.Control.IsExpanded = false;
            var next = original with { Enabled = true };
            section.Update(new([next], true), next);
            Check(!section.Control.IsExpanded && ReferenceEquals(master, section.Control.Content),
                "Preference update reopened or replaced the section.");
            Check(details.Children.OfType<TextBlock>().Any(text => text.Text == Localizer.Get("GameExtensions.WorldRequired")),
                "World-required hint was lost.");
            section.Update(new([next], true, VehicleStatus: new(RuntimeExtensionState.Pending, "safe-boundary"), RuntimeWorldReady: true), next);
            Check(details.Children.OfType<TextBlock>().Any(text => text.Text == Localizer.Get("GameExtensions.ApplyWhenSafe")),
                "Safe-boundary hint was lost.");
            section.Update(new([next], true, VehicleStatus: new(RuntimeExtensionState.FaultedPassThrough, "test-failure"), RuntimeWorldReady: true), next);
            Check(details.Children.OfType<TextBlock>().Any(text => text.Text == Localizer.Get("GameExtensions.InitializationFailed")),
                "Failure hint was lost.");
            section.Control.IsExpanded = true;
            host.UpdateLayout();
            if (new Windows.UI.ViewManagement.UISettings().AnimationsEnabled)
                Check(expansion.CurrentState?.Storyboard?.GetCurrentState() == ClockState.Active,
                    "Initial layout completion disabled later user expansion animation.");
        }
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        yield return parent;
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
            foreach (var child in Descendants(VisualTreeHelper.GetChild(parent, index))) yield return child;
    }

    private static async Task SettleAsync(FrameworkElement root)
    {
        root.UpdateLayout();
        await Task.Delay(250);
        root.UpdateLayout();
    }

    private async Task SavePngAsync(UIElement source, string filename, int width, int height)
    {
        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(source, width, height);
        Check(bitmap.PixelWidth > 0 && bitmap.PixelHeight > 0, "Empty render.");
        var buffer = await bitmap.GetPixelsAsync();
        var pixels = new byte[checked((int)buffer.Length)];
        using (var reader = DataReader.FromBuffer(buffer)) reader.ReadBytes(pixels);
        var folder = await StorageFolder.GetFolderFromPathAsync(outputDirectory);
        var file = await folder.CreateFileAsync(filename, CreationCollisionOption.ReplaceExisting);
        using var stream = await file.OpenAsync(FileAccessMode.ReadWrite);
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels);
        await encoder.FlushAsync();
    }

    private void Fail(Exception error)
    {
        Environment.ExitCode = 1;
        File.WriteAllText(Path.Combine(outputDirectory, "result.txt"), "FAIL: " + error);
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
