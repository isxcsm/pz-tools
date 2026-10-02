using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.UI.ViewManagement;

namespace PzTools.App;

public enum HomeDestination
{
    Saves,
    Settings,
    Extensions,
    Profiler,
}

public enum HomeGameState { Unknown, Playing, NotPlaying }

/// <summary>
/// What the Home page says about now. Built from the app's live views by the shell (HomeStatusSource);
/// the page itself reads nothing, so it renders the same with no host at all (before the views arrive, or in a test).
/// </summary>
public sealed record HomeStatus(
    HomeGameState Game,
    string? PlayingSave,
    bool AutomaticBackupOff,
    bool SavesKnown,
    string? SaveName,
    string? SaveMode,
    DateTimeOffset? LastBackupUtc,
    bool ExtensionsKnown,
    bool VehicleEnabled,
    bool VehicleWaiting,
    int VehicleFeatures)
{
    public static HomeStatus Unknown { get; } = new(HomeGameState.Unknown, null, false, false, null, null, null, false, false, false, 0);
}

public sealed partial class HomePage : UserControl
{
    private readonly UISettings uiSettings = new();
    // "12 minutes ago" goes stale on its own; redraw it while the page is shown.
    private readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(30) };
    private HomeStatus status = HomeStatus.Unknown;
    private bool? wideLayout;

    public event EventHandler<HomeDestination>? NavigationRequested;

    // From <Version> in Directory.Build.props; the SDK may append "+<commit>", which is not shown.
    internal static string AppVersionText()
    {
        var version = typeof(HomePage).Assembly
            .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
            .OfType<System.Reflection.AssemblyInformationalVersionAttribute>().FirstOrDefault()?.InformationalVersion;
        return string.IsNullOrEmpty(version) ? "" : "v" + version.Split('+')[0];
    }

    public HomePage()
    {
        InitializeComponent();
        HomeVersion.Text = AppVersionText();
        ApplyLocalizedText();
        Loaded += HomePage_Loaded;
        Unloaded += HomePage_Unloaded;
        clock.Tick += (_, _) => ShowStatus(status);
    }

    internal void ApplyLocalizedText()
    {
        Language = Localizer.Culture.Name;
        HomeDescription.Text = KeepWords(Localizer.Get("Home.Description"));
        HomeFeaturesHeading.Text = Localizer.Get("Home.FeaturesHeading");
        HomeBackupTitle.Text = Localizer.Get("Home.BackupTitle");
        HomeBackupDescription.Text = KeepWords(Localizer.Get("Home.BackupDescription"));
        HomeBackupAction.Text = Localizer.Get("SavesNavigation.Content");
        HomeRecoveryTitle.Text = Localizer.Get("Home.RecoveryTitle");
        HomeRecoveryDescription.Text = KeepWords(Localizer.Get("Home.RecoveryDescription"));
        HomeRecoveryAction.Text = Localizer.Get("SavesNavigation.Content");
        HomeProfilerTitle.Text = Localizer.Get("ProfilerNavigation");
        HomeProfilerDescription.Text = KeepWords(Localizer.Get("Home.ProfilerDescription"));
        HomeProfilerAction.Text = Localizer.Get("ProfilerNavigation");
        HomeExtensionsTitle.Text = Localizer.Get("GameExtensions.Title");
        HomeExtensionsDescription.Text = KeepWords(Localizer.Get("Home.ExtensionsDescription"));
        HomeExtensionsAction.Text = Localizer.Get("GameExtensions.Title");
        ReportIssueButton.Content = Localizer.Get("Home.ReportIssue");
        HomeUnofficialNotice.Text = Localizer.Get("Home.UnofficialNotice");
        AutomationProperties.SetName(BackupButton, HomeBackupTitle.Text);
        AutomationProperties.SetName(CharacterRecoveryButton, HomeRecoveryTitle.Text);
        AutomationProperties.SetName(ProfilerButton, HomeProfilerTitle.Text);
        AutomationProperties.SetName(GameExtensionsButton, HomeExtensionsTitle.Text);
        ShowStatus(status);
    }

    /// <summary>Shows the state rows. Called by the shell whenever one of the views behind them changes.</summary>
    public void ShowStatus(HomeStatus value)
    {
        status = value;

        Set(GameStatusValue, Localizer.Get(value.Game switch
        {
            HomeGameState.Playing => "Home.GamePlaying",
            HomeGameState.NotPlaying => "Home.GameNotPlaying",
            _ => "Home.GameChecking",
        }));
        Show(GameLiveDot, value.Game == HomeGameState.Playing);
        Detail(GameStatusDetail, value.AutomaticBackupOff ? Localizer.Get("AutomaticBackupOff") : "");

        Set(SaveStatusValue, !value.SavesKnown ? Localizer.Get("Home.SaveChecking")
            : value.SaveName ?? Localizer.Get("Home.NoSave"));
        var known = value.SavesKnown && value.SaveName is not null;
        Detail(SaveStatusDetail, known && value.LastBackupUtc is { } last ? Localizer.Format("Home.LastBackup", Ago(last)) : "");
        Detail(SaveStatusWarning, known && value.LastBackupUtc is null ? Localizer.Get("Home.NoBackup") : "");

        Set(ExtensionStatusValue, Localizer.Get(!value.ExtensionsKnown ? "Home.ExtensionChecking"
            : value.VehicleWaiting ? "Home.VehicleWaiting"
            : value.VehicleEnabled ? "Home.VehicleOn" : "Home.VehicleOff"));
        Detail(ExtensionStatusDetail, value.ExtensionsKnown && value.VehicleEnabled
            ? Localizer.Format("Home.ExtensionFeatures", value.VehicleFeatures) : "");
        Detail(ExtensionStatusWarning, value.ExtensionsKnown && value.VehicleWaiting ? Localizer.Get("Home.ExtensionUnsupported") : "");

        SetAutomationName(GameStatusButton, Join(GameStatusValue.Text, GameStatusDetail.Text));
        SetAutomationName(SaveStatusButton, Join(SaveStatusValue.Text, SaveStatusDetail.Text, SaveStatusWarning.Text));
        SetAutomationName(ExtensionStatusButton, Join(ExtensionStatusValue.Text, ExtensionStatusDetail.Text, ExtensionStatusWarning.Text));
    }

    /// <summary>The part after the value, as "· text"; hidden when there is nothing to add.</summary>
    private static void Detail(TextBlock block, string text)
    {
        Set(block, text.Length > 0 ? "· " + KeepWords(text) : "");
        Show(block, text.Length > 0);
    }

    // Only what changed is assigned. This runs every 30 seconds for "N minutes ago", and an assignment,
    // even of the same text, makes the window draw again (also minimised or in the tray).
    private static void Set(TextBlock block, string text)
    {
        if (!string.Equals(block.Text, text, StringComparison.Ordinal)) block.Text = text;
    }

    private static void Show(UIElement element, bool visible)
    {
        var visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (element.Visibility != visibility) element.Visibility = visibility;
    }

    private static void SetAutomationName(UIElement element, string name)
    {
        if (!string.Equals(AutomationProperties.GetName(element), name, StringComparison.Ordinal))
            AutomationProperties.SetName(element, name);
    }

    private static string Join(params string[] parts) =>
        string.Join(", ", parts.Where(part => part.Length > 0).Select(part => part.TrimStart('·', ' ')));

    /// <summary>"Just now", "12 minutes ago", "3 hours ago", "2 days ago".</summary>
    internal static string Ago(DateTimeOffset utc)
    {
        var elapsed = DateTimeOffset.UtcNow - utc;
        if (elapsed < TimeSpan.FromMinutes(1)) return Localizer.Get("Home.AgoNow");
        if (elapsed < TimeSpan.FromHours(1)) return Localizer.Format("Home.AgoMinutes", (int)elapsed.TotalMinutes);
        if (elapsed < TimeSpan.FromDays(1)) return Localizer.Format("Home.AgoHours", (int)elapsed.TotalHours);
        return Localizer.Format("Home.AgoDays", (int)elapsed.TotalDays);
    }

    /// <summary>
    /// Korean is broken between any two syllables by default, so a word could be split across lines
    /// ("내 / 보내거나"). A word joiner between the syllables of a word leaves only the spaces to break at.
    /// Text without Hangul is returned as it is.
    /// </summary>
    internal static string KeepWords(string text)
    {
        static bool Hangul(char c) => c is >= '가' and <= '힣';
        if (!text.Any(Hangul)) return text;
        var result = new StringBuilder(text.Length * 2);
        for (var index = 0; index < text.Length; index++)
        {
            result.Append(text[index]);
            if (index + 1 < text.Length && !char.IsWhiteSpace(text[index]) && !char.IsWhiteSpace(text[index + 1])
                && (Hangul(text[index]) || Hangul(text[index + 1])))
                result.Append('\u2060'); // WORD JOINER
        }
        return result.ToString();
    }

    private void HomePage_Loaded(object sender, RoutedEventArgs e)
    {
        uiSettings.TextScaleFactorChanged += TextScaleFactor_Changed;
        UpdateLayoutForWidth();
        ShowStatus(status);
        clock.Start();
    }

    private void HomePage_Unloaded(object sender, RoutedEventArgs e)
    {
        uiSettings.TextScaleFactorChanged -= TextScaleFactor_Changed;
        clock.Stop();
    }

    private void TextScaleFactor_Changed(UISettings sender, object args) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            if (IsLoaded) UpdateLayoutForWidth();
        });

    private void HomePage_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateLayoutForWidth();

    internal static bool UseWideLayout(double availableWidth, double textScaleFactor) =>
        availableWidth >= 680 * Math.Max(1, textScaleFactor);

    private void UpdateLayoutForWidth()
    {
        if (HomeContent is null || IntroductionGrid is null || FeatureGrid is null) return;
        var wide = UseWideLayout(ActualWidth, uiSettings.TextScaleFactor);
        if (wideLayout == wide) return;
        wideLayout = wide;

        // Wide, the artwork stands at the right edge, level with the cards' right edge below it.
        // It is drawn 40 taller than the room it takes, hanging into the empty right end of the
        // "Features" heading line, so it can be large without pushing the cards down or the text apart.
        IntroductionGrid.ColumnDefinitions[1].Width = new GridLength(wide ? 240 : 0);
        IntroductionGrid.ColumnSpacing = wide ? 24 : 0;
        IntroductionGrid.RowSpacing = wide ? 0 : 16;
        Grid.SetRow(IntroductionCopy, wide ? 0 : 1);
        Grid.SetColumn(HomeArtwork, wide ? 1 : 0);
        HomeArtwork.Height = wide ? 240 : 128;
        HomeArtwork.Margin = new Thickness(0, 0, 0, wide ? -40 : 0);
        HomeArtwork.HorizontalAlignment = wide ? HorizontalAlignment.Right : HorizontalAlignment.Left;

        FeatureGrid.ColumnDefinitions[1].Width = wide
            ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        FeatureGrid.ColumnSpacing = wide ? 12 : 0;
        Grid.SetRow(CharacterRecoveryButton, wide ? 0 : 1);
        Grid.SetColumn(CharacterRecoveryButton, wide ? 1 : 0);
        Grid.SetRow(ProfilerButton, wide ? 1 : 2);
        Grid.SetRow(GameExtensionsButton, wide ? 1 : 3);
        Grid.SetColumn(GameExtensionsButton, wide ? 1 : 0);
    }

    private void OpenSaves_Click(object sender, RoutedEventArgs e) =>
        NavigationRequested?.Invoke(this, HomeDestination.Saves);

    private void OpenProfiler_Click(object sender, RoutedEventArgs e) =>
        NavigationRequested?.Invoke(this, HomeDestination.Profiler);

    private void OpenExtensions_Click(object sender, RoutedEventArgs e) =>
        NavigationRequested?.Invoke(this, HomeDestination.Extensions);
}
