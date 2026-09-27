using System.Reflection;
using System.Xml.Linq;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media.Imaging;
using PzTools.App.Core;
using PzTools.Projections;
using Windows.Graphics;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace PzTools.App;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Length != 1) throw new ArgumentException("Usage: PzTools.LogsSmoke.exe <output-directory>");
        var output = Path.GetFullPath(args[0]);
        Directory.CreateDirectory(output);
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(parameters =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App(output);
        });
    }
}

// Only the Application identity needed by LogsPage. No product App/AppHost is constructed.
internal sealed class App(string outputDirectory) : Application, IXamlMetadataProvider
{
    public AppHost? Host => null;
    public void ShowSidebarNotification(InfoBarSeverity severity, string title, string message) =>
        throw new InvalidOperationException($"Unexpected notification: {severity}: {title}: {message}");

    private IXamlMetadataProvider? metadata;
    private IXamlMetadataProvider Metadata => metadata ??= (IXamlMetadataProvider)Activator.CreateInstance(
        typeof(App).Assembly.GetType("PzTools.LogsSmoke.PzTools_LogsSmoke_XamlTypeInfo.XamlMetaDataProvider", true)!)!;
    public IXamlType GetXamlType(Type type) => Metadata.GetXamlType(type);
    public IXamlType GetXamlType(string fullName) => Metadata.GetXamlType(fullName);
    public XmlnsDefinition[] GetXmlnsDefinitions() => Metadata.GetXmlnsDefinitions();
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
            XNamespace presentation = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
            XNamespace xaml = "http://schemas.microsoft.com/winfx/2006/xaml";
            var document = XDocument.Load(Path.Combine(AppContext.BaseDirectory, "SmokeAppResources.xml"));
            var dictionary = new XElement(document.Root!.Element(presentation + "Application.Resources")!
                .Element(presentation + "ResourceDictionary")!);
            dictionary.SetAttributeValue("xmlns", presentation.NamespaceName);
            dictionary.SetAttributeValue(XNamespace.Xmlns + "x", xaml.NamespaceName);
            Resources = (ResourceDictionary)XamlReader.Load(dictionary.ToString());
            Localizer.SetLanguage(PzTools.Process.Contracts.SupportedLanguage.Korean);
            var host = (Grid)XamlReader.Load("""
                <Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                      Width="1140" Height="690" Padding="20" HorizontalAlignment="Left" VerticalAlignment="Top"
                      Background="{ThemeResource ApplicationPageBackgroundThemeBrush}" />
                """);
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
                        "PASS: Korean/English PRI localization; warning/filter/unfiltered/loading/failure states; " +
                        "reset via Invoke; unframed empty detail and populated selection; light/dark PNG renders. " +
                        "No AppHost/game/save/settings access.");
                }
                catch (Exception error) { WriteFailure(error); }
                finally { window.Close(); Exit(); }
            };
            window.Activate();
        }
        catch (Exception error) { WriteFailure(error); window?.Close(); Exit(); }
    }

    private async Task RunAsync(Grid host)
    {
        var scale = host.XamlRoot.RasterizationScale;
        window!.AppWindow.Resize(new SizeInt32((int)(host.Width * scale) + 32, (int)(host.Height * scale) + 64));
        var page = new LogsPage();
        host.Children.Add(page);
        await SettleAsync(host);
        Set(page, "hasLoadedLogs", true);
        Set(page, "isLoadingLogs", false);
        Set(page, "loadFailed", false);
        Call(page, "UpdateFilterChips");
        Call(page, "UpdateEmptyState");
        CheckState(page, "경고 이상 로그가 없습니다.", all: true);
        var placeholder = Find<Border>(page, "NoLogSelectedCard");
        Check(placeholder.Background is null && placeholder.BorderBrush is null
            && placeholder.BorderThickness == new Thickness(0), "Empty detail should be unframed.");
        Check(placeholder.ActualWidth > 0 && placeholder.Visibility == Visibility.Visible,
            "Empty detail must preserve its layout column.");
        foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
        {
            host.RequestedTheme = theme;
            await SettleAsync(host);
            await SavePngAsync(host, "logs-empty-" + theme.ToString().ToLowerInvariant() + ".png");
        }

        Set(page, "componentCategory", "Backup");
        Set(page, "logRange", new LogNumberRange(1, 10));
        Set(page, "runRange", new LogNumberRange(3, 7));
        Set(page, "timeRange", new LogTimeRange(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow));
        Set(page, "timeFromText", "2026-09-26 00:00");
        Set(page, "timeThroughText", "2026-09-27 00:00");
        Set(page, "pageIndex", 3);
        Set(page, "pageSnapshot", 1000L);
        bool? commitPending = null;
        Set(page, "stopFilterEdit", (Action<bool>)(value => commitPending = value));
        Call(page, "UpdateFilterChips");
        Call(page, "UpdateEmptyState");
        CheckState(page, "선택한 필터에 맞는 로그가 없습니다.", all: true);
        var button = Find<HyperlinkButton>(page, "ShowAllLogsButton");
        var peer = FrameworkElementAutomationPeer.CreatePeerForElement(button) ?? new HyperlinkButtonAutomationPeer(button);
        ((IInvokeProvider)peer.GetPattern(PatternInterface.Invoke)).Invoke();
        await SettleAsync(host);
        Check(commitPending == false, "Reset must discard pending filter-editor changes.");
        Check(Get<LogLevel>(page, "minimumLevel") == Get<LogLevel>(page, "recordMinimum")
            && Get<bool>(page, "levelChosenByUser") && Get<string>(page, "componentCategory") == "All"
            && Get<object?>(page, "logRange") is null && Get<object?>(page, "runRange") is null
            && Get<object?>(page, "timeRange") is null && Get<string>(page, "timeFromText") == ""
            && Get<string>(page, "timeThroughText") == "" && Get<int>(page, "pageIndex") == 0
            && Get<long>(page, "pageSnapshot") == 0, "View all did not reset every filter and paging cursor.");
        Call(page, "UpdateEmptyState");
        CheckState(page, "표시할 로그가 없습니다.", all: false);

        Set(page, "isLoadingLogs", true);
        Call(page, "UpdateEmptyState");
        Check(Find<StackPanel>(page, "LoadingLogs").Visibility == Visibility.Visible
            && Find<StackPanel>(page, "EmptyLogs").Visibility == Visibility.Collapsed
            && button.Visibility == Visibility.Collapsed, "Loading was reported as an empty success.");
        Set(page, "isLoadingLogs", false);
        Set(page, "loadFailed", true);
        Call(page, "UpdateEmptyState");
        CheckState(page, "로그를 불러올 수 없습니다.", all: false);
        Localizer.SetLanguage(PzTools.Process.Contracts.SupportedLanguage.English);
        page.ApplyLocalizedText();
        CheckState(page, Localizer.Get("LogsUnavailable"), all: false);
        Check(!Localizer.Get("LogShowAll").Contains('전'), "English PRI resource was not selected.");
        Localizer.SetLanguage(PzTools.Process.Contracts.SupportedLanguage.Korean);
        page.ApplyLocalizedText();

        Set(page, "loadFailed", false);
        Set(page, "source", (IReadOnlyList<LogEntryView>)[new("smoke", "backup", Guid.Empty, 1,
            DateTimeOffset.UtcNow, LogLevel.Information, "Backup", 1, "run.committed", "{}", 1)]);
        Set(page, "totalGroups", 1);
        Call(page, "ApplyFilter", false, false);
        var list = Find<ListView>(page, "LogList");
        list.SelectedIndex = 0;
        await SettleAsync(host);
        Check(Find<ScrollViewer>(page, "LogDetail").Visibility == Visibility.Visible
            && placeholder.Visibility == Visibility.Collapsed, "Populated detail failed to replace the placeholder.");
    }

    private static void CheckState(LogsPage page, string text, bool all)
    {
        Check(Find<TextBlock>(page, "EmptyLogsText").Text == text, "Unexpected empty-state message: " + Find<TextBlock>(page, "EmptyLogsText").Text);
        Check(Find<StackPanel>(page, "EmptyLogs").Visibility == Visibility.Visible
            && Find<StackPanel>(page, "LoadingLogs").Visibility == Visibility.Collapsed, "Incorrect placeholder visibility.");
        Check(Find<HyperlinkButton>(page, "ShowAllLogsButton").Visibility == (all ? Visibility.Visible : Visibility.Collapsed),
            "Incorrect View all visibility.");
    }

    private static T Find<T>(LogsPage page, string name) where T : FrameworkElement => (T)page.FindName(name);
    private static FieldInfo Field(string name) => typeof(LogsPage).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new MissingFieldException(name);
    private static void Set(LogsPage page, string name, object? value) => Field(name).SetValue(page, value);
    private static T Get<T>(LogsPage page, string name) => (T)Field(name).GetValue(page)!;
    private static void Call(LogsPage page, string name, params object[] values) =>
        typeof(LogsPage).GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(page, values);
    private static async Task SettleAsync(FrameworkElement root) { root.UpdateLayout(); await Task.Delay(200); root.UpdateLayout(); }

    private async Task SavePngAsync(UIElement source, string filename)
    {
        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(source, 1140, 690);
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
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
