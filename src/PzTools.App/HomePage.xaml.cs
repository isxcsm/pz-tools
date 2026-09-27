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
}

public sealed partial class HomePage : UserControl
{
    private readonly UISettings uiSettings = new();
    private bool? wideLayout;

    public event EventHandler<HomeDestination>? NavigationRequested;

    public HomePage()
    {
        InitializeComponent();
        ApplyLocalizedText();
        Loaded += HomePage_Loaded;
        Unloaded += HomePage_Unloaded;
    }

    internal void ApplyLocalizedText()
    {
        Language = Localizer.Culture.Name;
        HomeDescription.Text = Localizer.Get("Home.Description");
        HomeOpenSaves.Text = Localizer.Get("SavesNavigation.Content");
        HomeFeaturesHeading.Text = Localizer.Get("Home.FeaturesHeading");
        HomeBackupTitle.Text = Localizer.Get("Home.BackupTitle");
        HomeBackupDescription.Text = Localizer.Get("Home.BackupDescription");
        HomeBackupAction.Text = Localizer.Get("Home.BackupAction");
        HomeRestoreTitle.Text = Localizer.Get("Home.RestoreTitle");
        HomeRestoreDescription.Text = Localizer.Get("Home.RestoreDescription");
        HomeRestoreAction.Text = Localizer.Get("Home.RestoreAction");
        HomeRecoveryTitle.Text = Localizer.Get("Home.RecoveryTitle");
        HomeRecoveryDescription.Text = Localizer.Get("Home.RecoveryDescription");
        HomeRecoveryAction.Text = Localizer.Get("SavesNavigation.Content");
        HomeExtensionsTitle.Text = Localizer.Get("Extension.VehicleDrivetrain.Title");
        HomeExtensionsDescription.Text = Localizer.Get("Home.ExtensionsDescription");
        HomeExtensionsAction.Text = Localizer.Get("GameExtensions.Title");
        ReportIssueButton.Content = Localizer.Get("Home.ReportIssue");
        HomeUnofficialNotice.Text = Localizer.Get("Home.UnofficialNotice");
        AutomationProperties.SetName(OpenSavesButton, HomeOpenSaves.Text);
        AutomationProperties.SetName(AutomaticBackupButton, HomeBackupAction.Text);
        AutomationProperties.SetName(RestoreButton, HomeRestoreAction.Text);
        AutomationProperties.SetName(CharacterRecoveryButton, HomeRecoveryAction.Text);
        AutomationProperties.SetName(GameExtensionsButton, HomeExtensionsAction.Text);
    }

    private void HomePage_Loaded(object sender, RoutedEventArgs e)
    {
        uiSettings.TextScaleFactorChanged += TextScaleFactor_Changed;
        UpdateLayoutForWidth();
    }

    private void HomePage_Unloaded(object sender, RoutedEventArgs e) =>
        uiSettings.TextScaleFactorChanged -= TextScaleFactor_Changed;

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
        var wide = UseWideLayout(Math.Min(ActualWidth, HomeContent.MaxWidth), uiSettings.TextScaleFactor);
        if (wideLayout == wide) return;
        wideLayout = wide;

        IntroductionGrid.ColumnDefinitions[1].Width = new GridLength(wide ? 192 : 0);
        IntroductionGrid.ColumnSpacing = wide ? 24 : 0;
        IntroductionGrid.RowSpacing = wide ? 0 : 16;
        Grid.SetRow(IntroductionCopy, wide ? 0 : 1);
        Grid.SetColumn(HomeArtwork, wide ? 1 : 0);
        HomeArtwork.Height = wide ? 192 : 128;
        HomeArtwork.HorizontalAlignment = wide ? HorizontalAlignment.Center : HorizontalAlignment.Left;

        FeatureGrid.ColumnDefinitions[1].Width = wide
            ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        FeatureGrid.ColumnSpacing = wide ? 12 : 0;
        Grid.SetRow(RestoreButton, wide ? 0 : 1);
        Grid.SetColumn(RestoreButton, wide ? 1 : 0);
        Grid.SetRow(CharacterRecoveryButton, wide ? 1 : 2);
        Grid.SetRow(GameExtensionsButton, wide ? 1 : 3);
        Grid.SetColumn(GameExtensionsButton, wide ? 1 : 0);
    }

    private void OpenSaves_Click(object sender, RoutedEventArgs e) =>
        NavigationRequested?.Invoke(this, HomeDestination.Saves);

    private void OpenSettings_Click(object sender, RoutedEventArgs e) =>
        NavigationRequested?.Invoke(this, HomeDestination.Settings);

    private void OpenExtensions_Click(object sender, RoutedEventArgs e) =>
        NavigationRequested?.Invoke(this, HomeDestination.Extensions);
}
