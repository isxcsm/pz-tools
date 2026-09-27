using System.Text.Json;
using System.Xml.Linq;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using PzTools.App;
using PzTools.Process.Contracts;
using Windows.Graphics;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace PzTools.HomeSmoke;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Length is < 1 or > 2 || (args.Length == 2 && args[1] != "--visible"))
            throw new ArgumentException("Usage: PzTools.HomeSmoke.exe <output-directory> [--visible]");
        var output = Path.GetFullPath(args[0]);
        Directory.CreateDirectory(output);
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(parameters =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new SmokeApp(output, args.Length == 2);
        });
    }
}

internal sealed class SmokeApp(string outputDirectory, bool visible) : Application, IXamlMetadataProvider
{
    // The provider is emitted after WinUI's first C# compile pass. Resolve it at
    // runtime so the standalone Application can expose the generated page types.
    private IXamlMetadataProvider? metadata;
    private IXamlMetadataProvider Metadata => metadata ??= (IXamlMetadataProvider)Activator.CreateInstance(
        typeof(SmokeApp).Assembly.GetType("PzTools.HomeSmoke.PzTools_HomeSmoke_XamlTypeInfo.XamlMetaDataProvider", throwOnError: true)!)!;

    public IXamlType GetXamlType(Type type) => Metadata.GetXamlType(type);
    public IXamlType GetXamlType(string fullName) => Metadata.GetXamlType(fullName);
    public XmlnsDefinition[] GetXmlnsDefinitions() => Metadata.GetXmlnsDefinitions();

    private static readonly (string Name, HomeDestination Destination)[] Actions =
    [
        ("OpenSavesButton", HomeDestination.Saves),
        ("AutomaticBackupButton", HomeDestination.Settings),
        ("RestoreButton", HomeDestination.Saves),
        ("CharacterRecoveryButton", HomeDestination.Saves),
        ("GameExtensionsButton", HomeDestination.Extensions),
    ];

    private readonly List<object> captures = [];
    private Window? window;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        UnhandledException += (_, error) =>
        {
            WriteFailure(error.Exception);
            error.Handled = true;
            window?.Close();
            Exit();
        };
        try
        {
            // Load only the production resource dictionary, never App or AppHost.
            XNamespace presentation = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
            XNamespace xaml = "http://schemas.microsoft.com/winfx/2006/xaml";
            var document = XDocument.Load(Path.Combine(AppContext.BaseDirectory, "SmokeAppResources.xml"));
            var dictionary = new XElement(document.Root!
                .Element(presentation + "Application.Resources")!
                .Element(presentation + "ResourceDictionary")!);
            dictionary.SetAttributeValue("xmlns", presentation.NamespaceName);
            dictionary.SetAttributeValue(XNamespace.Xmlns + "x", xaml.NamespaceName);
            Resources = (ResourceDictionary)XamlReader.Load(dictionary.ToString());

            var host = (Grid)XamlReader.Load("""
                <Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                      Width="1280" Height="920" HorizontalAlignment="Left" VerticalAlignment="Top"
                      Background="{ThemeResource ApplicationPageBackgroundThemeBrush}" />
                """);
            window = new Window { Content = host };
            var started = false;
            host.Loaded += async (_, _) =>
            {
                if (started) return;
                started = true;
                try
                {
                    if (!visible) window.AppWindow.Hide();
                    await RunAsync(host);
                    File.WriteAllText(Path.Combine(outputDirectory, "result.txt"),
                        "PASS: 4 viewport/theme combinations, 20 CTA invokes, 4 navigation SVG loads/renders; " +
                        "18 live language switches, localized text/accessibility, 36 localized layout renders; no AppHost/game/save/settings access.");
                }
                catch (Exception error) { WriteFailure(error); }
                finally
                {
                    File.WriteAllText(Path.Combine(outputDirectory, "layout.json"),
                        JsonSerializer.Serialize(captures, new JsonSerializerOptions { WriteIndented = true }));
                    window.Close();
                    Exit();
                }
            };
            window.Activate();
        }
        catch (Exception error)
        {
            WriteFailure(error);
            window?.Close();
            Exit();
        }
    }

    private async Task RunAsync(Grid host)
    {
        Localizer.SetLanguage(SupportedLanguage.Korean);
        Check(!HomePage.UseWideLayout(679, 1) && HomePage.UseWideLayout(680, 1)
            && !HomePage.UseWideLayout(1040, 2), "Responsive width/text-scale policy failed.");
        foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
        foreach (var viewport in new[] { (Name: "wide", Width: 1280, Height: 920), (Name: "narrow", Width: 640, Height: 720) })
        {
            host.RequestedTheme = theme;
            host.Width = viewport.Width;
            host.Height = viewport.Height;
            host.Children.Clear();
            var page = new HomePage();
            var failures = new List<string>();
            var navigation = new List<HomeDestination>();
            page.NavigationRequested += (_, destination) => navigation.Add(destination);
            host.Children.Add(page);
            var scale = host.XamlRoot.RasterizationScale;
            window!.AppWindow.Resize(new SizeInt32(
                (int)Math.Ceiling(viewport.Width * scale) + 32,
                (int)Math.Ceiling(viewport.Height * scale) + 64));
            await SettleAsync(host);
            var images = Descendants(page).OfType<Image>().ToArray();
            foreach (var image in images)
                image.ImageFailed += (_, error) => failures.Add(error.ErrorMessage);
            for (var retry = 0; retry < 50 && images.Any(IsImagePending); retry++)
                await Task.Delay(100);
            Check(failures.Count == 0 && images.All(image => !IsImagePending(image)),
                "Home artwork did not load: " + string.Join("; ", failures));
            Check(Math.Abs(page.ActualWidth - viewport.Width) < 2, "Home page did not occupy the requested viewport.");
            await SettleAsync(host);
            var content = (FrameworkElement)page.FindName("HomeContent");
            var contentOrigin = content.TransformToVisual(page).TransformPoint(new Windows.Foundation.Point());
            Check(Math.Abs(contentOrigin.X) < 1, "Home content must share the shell's left alignment.");
            if (viewport.Name == "wide")
            {
                var introduction = (FrameworkElement)page.FindName("IntroductionCopy");
                var introductionOrigin = introduction.TransformToVisual(page).TransformPoint(new Windows.Foundation.Point());
                Check(Math.Abs(introductionOrigin.Y) < 1, "Wide Home title must align with other page headers.");
            }
            var version = page.FindName("HomeVersion") as TextBlock;
            Check(version is { Text: "v0.1.0", IsTextSelectionEnabled: true }
                && version.ActualWidth > 0 && version.ActualHeight > 0 && !version.IsTextTrimmed,
                "Home footer must display the selectable app version.");

            var buttonBounds = new List<object>();
            foreach (var (name, _) in Actions)
            {
                var button = FindButton(page, name);
                var bounds = button.TransformToVisual(page).TransformBounds(
                    new Windows.Foundation.Rect(0, 0, button.ActualWidth, button.ActualHeight));
                Check(button.IsEnabled && button.Visibility == Visibility.Visible
                    && bounds.Width > 0 && bounds.Height > 0, name + " is not an enabled laid-out CTA.");
                Check(bounds.X >= -1 && bounds.Right <= page.ActualWidth + 1,
                    name + " extends horizontally beyond the viewport.");
                buttonBounds.Add(new { name, bounds.X, bounds.Y, bounds.Width, bounds.Height });
            }

            var stem = $"home-{viewport.Name}-{theme.ToString().ToLowerInvariant()}";
            await SavePngAsync(host, stem + ".png", viewport.Width, viewport.Height);
            var scroller = Descendants(page).OfType<ScrollViewer>()
                .OrderByDescending(item => item.ScrollableHeight).FirstOrDefault();
            if (viewport.Name == "narrow")
                Check(scroller is not null && scroller.ScrollableHeight > 1, "Narrow viewport did not exercise scrolling.");
            if (scroller is not null && scroller.ScrollableHeight > 1)
            {
                scroller.ChangeView(null, scroller.ScrollableHeight, null, disableAnimation: true);
                await SettleAsync(host);
                await SavePngAsync(host, stem + "-bottom.png", viewport.Width, viewport.Height);
                scroller.ChangeView(null, 0, null, disableAnimation: true);
                await SettleAsync(host);
            }

            foreach (var (name, destination) in Actions)
            {
                var button = FindButton(page, name);
                button.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
                await SettleAsync(host);
                var visibleBounds = button.TransformToVisual(page).TransformBounds(
                    new Windows.Foundation.Rect(0, 0, button.ActualWidth, button.ActualHeight));
                Check(visibleBounds.Y >= -1 && visibleBounds.Bottom <= page.ActualHeight + 1,
                    name + " cannot be scrolled fully into the viewport.");
                var peer = FrameworkElementAutomationPeer.CreatePeerForElement(button) ?? new ButtonAutomationPeer(button);
                var invoke = peer.GetPattern(PatternInterface.Invoke) as IInvokeProvider
                    ?? throw new InvalidOperationException(name + " does not expose Invoke.");
                navigation.Clear();
                invoke.Invoke();
                await Task.Delay(50);
                Check(navigation.Count == 1 && navigation[0] == destination,
                    name + " did not emit exactly one " + destination + " navigation event.");
            }
            captures.Add(new
            {
                name = stem, viewport.Width, viewport.Height, theme = theme.ToString(), rasterizationScale = scale,
                imageCount = images.Length, ctaBounds = buttonBounds,
                scrollableHeight = scroller?.ScrollableHeight ?? 0,
                trimmedText = Descendants(page).OfType<TextBlock>().Where(text => text.IsTextTrimmed)
                    .Select(text => new { text.Name, text.Text }).ToArray(),
                navigationChecks = Actions.Length,
            });
        }
        await CheckLocalizedHomeAsync(host);
        await CheckNavigationIconsAsync(host);
    }

    private async Task CheckLocalizedHomeAsync(Grid host)
    {
        host.Children.Clear();
        host.RequestedTheme = ElementTheme.Light;
        var page = new HomePage();
        host.Children.Add(page);
        var localizedText = new Dictionary<string, string>
        {
            ["HomeDescription"] = "Home.Description",
            ["HomeOpenSaves"] = "SavesNavigation.Content",
            ["HomeFeaturesHeading"] = "Home.FeaturesHeading",
            ["HomeBackupTitle"] = "Home.BackupTitle",
            ["HomeBackupDescription"] = "Home.BackupDescription",
            ["HomeBackupAction"] = "Home.BackupAction",
            ["HomeRestoreTitle"] = "Home.RestoreTitle",
            ["HomeRestoreDescription"] = "Home.RestoreDescription",
            ["HomeRestoreAction"] = "Home.RestoreAction",
            ["HomeRecoveryTitle"] = "Home.RecoveryTitle",
            ["HomeRecoveryDescription"] = "Home.RecoveryDescription",
            ["HomeRecoveryAction"] = "SavesNavigation.Content",
            ["HomeExtensionsTitle"] = "Extension.VehicleDrivetrain.Title",
            ["HomeExtensionsDescription"] = "Home.ExtensionsDescription",
            ["HomeExtensionsAction"] = "GameExtensions.Title",
            ["HomeUnofficialNotice"] = "Home.UnofficialNotice",
        };
        foreach (var language in LanguageCatalog.All)
        {
            Localizer.SetLanguage(language.Id);
            page.ApplyLocalizedText();
            Check(page.Language == language.Tag, "Home retained the previous language.");
            Check(!string.IsNullOrWhiteSpace(Localizer.Get("HomeNavigation.Content")), "Home menu translation missing.");
            foreach (var (name, key) in localizedText)
                Check(((TextBlock)page.FindName(name)).Text == Localizer.Get(key), language.Tag + ": stale " + name);
            Check(Equals(((HyperlinkButton)page.FindName("ReportIssueButton")).Content, Localizer.Get("Home.ReportIssue")),
                language.Tag + ": issue link retained the previous language.");
            foreach (var (name, key) in new[]
            {
                ("OpenSavesButton", "SavesNavigation.Content"), ("AutomaticBackupButton", "Home.BackupAction"),
                ("RestoreButton", "Home.RestoreAction"), ("CharacterRecoveryButton", "SavesNavigation.Content"),
                ("GameExtensionsButton", "GameExtensions.Title"),
            })
                Check(AutomationProperties.GetName(FindButton(page, name)) == Localizer.Get(key),
                    language.Tag + ": stale accessible name for " + name);
            foreach (var width in new[] { 1040, 640 })
            {
                host.Width = width;
                host.Height = 920;
                var scale = host.XamlRoot.RasterizationScale;
                window!.AppWindow.Resize(new SizeInt32((int)(width * scale) + 32, (int)(920 * scale) + 64));
                var scroller = Descendants(page).OfType<ScrollViewer>().First();
                scroller.ChangeView(null, 0, null, disableAnimation: true);
                await SettleAsync(host);
                foreach (var text in Descendants(page).OfType<TextBlock>())
                {
                    Check(!text.IsTextTrimmed, language.Tag + ": trimmed text: " + text.Text);
                    var bounds = text.TransformToVisual(page).TransformBounds(
                        new Windows.Foundation.Rect(0, 0, text.ActualWidth, text.ActualHeight));
                    Check(bounds.X >= -1 && bounds.Right <= page.ActualWidth + 1,
                        language.Tag + ": horizontal text overflow: " + text.Text);
                }
                var stem = $"home-{language.Tag}-{width}";
                await SavePngAsync(host, stem + ".png", width, 920);
                if (scroller.ScrollableHeight > 0)
                {
                    scroller.ChangeView(null, scroller.ScrollableHeight, null, disableAnimation: true);
                    await SettleAsync(host);
                    var footer = (FrameworkElement)page.FindName("HomeUnofficialNotice");
                    var bottom = footer.TransformToVisual(page).TransformPoint(new Windows.Foundation.Point(0, footer.ActualHeight));
                    Check(bottom.Y <= page.ActualHeight + 1, language.Tag + ": footer cannot be reached by scrolling.");
                    await SavePngAsync(host, stem + "-bottom.png", width, 920);
                }
            }
        }
    }

    private async Task CheckNavigationIconsAsync(Grid host)
    {
        foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
        {
            host.RequestedTheme = theme;
            host.Width = 400;
            host.Height = 128;
            host.Children.Clear();
            var strip = new StackPanel { Margin = new Thickness(24), Spacing = 16 };
            host.Children.Add(strip);
            var pending = new List<Task>();
            var icons = new List<ImageIcon>();
            foreach (var (asset, label) in new[] { ("home", "Home"), ("extensions", "Apps") })
            {
                var loaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                var source = new SvgImageSource();
                source.Opened += (_, _) => loaded.TrySetResult();
                source.OpenFailed += (_, error) => loaded.TrySetException(
                    new InvalidOperationException(asset + ".svg did not load: " + error.Status));
                var icon = new ImageIcon { Width = 20, Height = 20, Source = source };
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
                row.Children.Add(icon);
                row.Children.Add(new TextBlock { Text = label + " — 20 px", VerticalAlignment = VerticalAlignment.Center });
                strip.Children.Add(row);
                source.UriSource = new Uri("ms-appx:///Assets/Navigation/" + asset + ".svg");
                icons.Add(icon);
                pending.Add(loaded.Task);
            }
            await Task.WhenAll(pending).WaitAsync(TimeSpan.FromSeconds(10));
            await SettleAsync(host);
            foreach (var icon in icons)
            {
                var bitmap = new RenderTargetBitmap();
                await bitmap.RenderAsync(icon, 20, 20);
                var buffer = await bitmap.GetPixelsAsync();
                var pixels = new byte[checked((int)buffer.Length)];
                using (var reader = DataReader.FromBuffer(buffer)) reader.ReadBytes(pixels);
                Check(pixels.Where((_, index) => index % 4 == 3).Any(alpha => alpha > 0),
                    "Navigation SVG loaded but rendered no visible pixels.");
            }
            var stem = "navigation-icons-" + theme.ToString().ToLowerInvariant();
            await SavePngAsync(host, stem + ".png", 400, 128);
            captures.Add(new { name = stem, theme = theme.ToString(), navigationSvgChecks = icons.Count });
        }
    }

    private static bool IsImagePending(Image image) => image.Source is BitmapImage bitmap && bitmap.PixelWidth == 0;

    private static Button FindButton(HomePage page, string name) => page.FindName(name) as Button
        ?? Descendants(page).OfType<Button>().FirstOrDefault(button => AutomationProperties.GetAutomationId(button) == name)
        ?? throw new InvalidOperationException("Missing CTA: " + name);

    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        var pending = new Queue<DependencyObject>();
        pending.Enqueue(parent);
        while (pending.TryDequeue(out var current))
        {
            yield return current;
            for (var index = 0; index < VisualTreeHelper.GetChildrenCount(current); index++)
                pending.Enqueue(VisualTreeHelper.GetChild(current, index));
        }
    }

    private static async Task SettleAsync(FrameworkElement root)
    {
        root.UpdateLayout();
        await Task.Delay(200);
        root.UpdateLayout();
    }

    private async Task SavePngAsync(UIElement source, string filename, int width, int height)
    {
        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(source, width, height);
        Check(bitmap.PixelWidth > 0 && bitmap.PixelHeight > 0, "RenderTargetBitmap produced an empty capture.");
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

    private void WriteFailure(Exception error)
    {
        Environment.ExitCode = 1;
        File.WriteAllText(Path.Combine(outputDirectory, "result.txt"), "FAIL: " + error);
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
