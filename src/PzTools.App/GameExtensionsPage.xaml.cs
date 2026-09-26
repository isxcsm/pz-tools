using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.App;

public sealed partial class GameExtensionsPage : UserControl
{
    private GameExtensionsView? snapshot;
    private bool refreshing;
    private bool applying;
    private bool dialogOpen;
    private IDisposable? subscription;
    private long viewRevision;
    private readonly Dictionary<string, ToggleSwitch> toggles = new(StringComparer.Ordinal);
    private App App => (App)Application.Current;

    public GameExtensionsPage()
    {
        InitializeComponent();
        ApplyLocalizedText();
        Loaded += async (_, _) =>
        {
            subscription?.Dispose();
            subscription = App.Host?.Views.Subscribe((key, _) =>
            {
                if (key == GameExtensionController.ViewKey) DispatcherQueue.TryEnqueue(ApplyLatestView);
            });
            await RefreshForNavigationAsync();
        };
        Unloaded += (_, _) => { subscription?.Dispose(); subscription = null; };
    }

    internal void ApplyLocalizedText()
    {
        Language = Localizer.Culture.Name;
        PageTitle.Text = Localizer.Get("GameExtensions.Title");
        ErrorInfo.Title = Localizer.Get("GameExtensions.SettingsError");
        if (snapshot is not null) Render(snapshot);
    }

    internal async Task RefreshForNavigationAsync()
    {
        if (refreshing || applying) return;
        var host = App.Host;
        if (host is null) return;
        refreshing = true;
        LoadingIndicator.Visibility = snapshot is null ? Visibility.Visible : Visibility.Collapsed;
        LoadingIndicator.IsActive = snapshot is null;
        try { Render(await host.GameExtensions.RefreshAsync()); }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException)
        { ShowSettingsError(); }
        finally { refreshing = false; LoadingIndicator.IsActive = false; LoadingIndicator.Visibility = Visibility.Collapsed; }
    }

    private void ApplyLatestView()
    {
        if (applying || dialogOpen || App.Host is not { } host) return;
        var changed = host.Views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, viewRevision);
        if (changed.Modified && changed.Snapshot is { } view) { viewRevision = changed.ViewRevision; Render(view); }
    }
    private static string VersionDescription(ExtensionCardView card)
    {
        var support = card.Definition.SupportedVersions ?? GameVersionSupport.All;
        string range = support.Scope == VersionSupportScope.All ? Localizer.Get("GameExtensions.VersionAll")
            : Localizer.Format(support.Scope == VersionSupportScope.Major ? "GameExtensions.VersionMajor" : "GameExtensions.VersionMinor", support.RangeText);
        return Localizer.Format("GameExtensions.VersionInfo", range, card.GameVersion ?? Localizer.Get("Unknown"));
    }
    private static string StatusText(ExtensionCardView item) => Localizer.Get(item.StatusCode switch
    {
        "version-mismatch" => "GameExtensions.VersionMismatch",
        "version-unknown" => "GameExtensions.VersionUnknown",
        "forced-version" => "GameExtensions.ForcedVersion",
        "disabled" => "GameExtensions.Disabled",
        _ => "GameExtensions.AwaitingValidation",
    });
    private void Render(GameExtensionsView view)
    {
        snapshot = view;
        Cards.Children.Clear();
        toggles.Clear();
        foreach (var item in view.Cards)
        {
            var description = new StackPanel { Spacing = 4 };
            description.Children.Add(new TextBlock
            {
                Text = Localizer.Get(item.Definition.DescriptionKey), TextWrapping = TextWrapping.Wrap,
            });
            description.Children.Add(new TextBlock
            {
                Text = !view.GameSavingEnabled && item.Definition.Capabilities.Contains("save.prepare.v1") ? Localizer.Get("GameSaveSetting.Header") + ": " + Localizer.Get("SettingDisabled")
                    : StatusText(item),
                TextWrapping = TextWrapping.Wrap,
            });
            description.Children.Add(new TextBlock { Text = VersionDescription(item), TextWrapping = TextWrapping.Wrap, Opacity = 0.7 });
            if (view.LastSave is { } last && last.RequestedProvider == item.Definition.Id)
            {
                string text = last.Outcome switch
                {
                    RuntimeSaveOutcome.Running => Localizer.Get("GameExtensions.ExecutionRunning"),
                    RuntimeSaveOutcome.Failed => Localizer.Format("GameExtensions.ExecutionFailed", last.Reason ?? "save-failed"),
                    _ when last.Provider != item.Definition.Id => Localizer.Format("GameExtensions.ExecutionFallback", last.Reason ?? "module-unavailable"),
                    _ => Localizer.Get("GameExtensions.ExecutionSucceeded"),
                };
                description.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap });
                if (last.Outcome != RuntimeSaveOutcome.Running)
                    description.Children.Add(new TextBlock { Text = Localizer.Format("GameExtensions.ExecutionTiming", last.GameThreadMilliseconds, last.ElapsedMilliseconds), TextWrapping = TextWrapping.Wrap, Opacity = 0.7 });
            }
            var toggle = new ToggleSwitch
            {
                IsOn = item.Enabled, IsEnabled = !applying && item.CanEnable,
                OnContent = Localizer.Get("SettingEnabled"), OffContent = Localizer.Get("SettingDisabled"),
            };
            AutomationProperties.SetName(toggle, Localizer.Get(item.Definition.TitleKey));
            toggle.Toggled += async (_, _) => await SetEnabledAsync(item, toggle.IsOn);
            toggles[item.Definition.Id] = toggle;
            // SettingsCard supplies native hover/pressed, keyboard and Invoke behavior.
            // Its interactive ToggleSwitch content keeps its own input handling.
            var card = new SettingsCard
            {
                Header = Localizer.Get(item.Definition.TitleKey), Description = description,
                HeaderIcon = new ImageIcon { Width = 20, Height = 20,
                    Source = new SvgImageSource(new Uri("ms-appx:///Assets/Navigation/extensions.svg")) },
                Content = toggle, IsClickEnabled = true, IsEnabled = !applying,
                IsActionIconVisible = true,
                ActionIconToolTip = Localizer.Get("GameExtensions.Configure"),
            };
            AutomationProperties.SetName(card, Localizer.Format("GameExtensions.ConfigureTitle", Localizer.Get(item.Definition.TitleKey)));
            card.Click += async (_, _) => await ConfigureAsync(item);
            Cards.Children.Add(card);
        }
    }

    private async Task ConfigureAsync(ExtensionCardView item)
    {
        if (applying || dialogOpen) return;
        dialogOpen = true;
        try
        {
            // The outer card owns activation. This dialog edits only extension options.
            var current = snapshot?.Cards.FirstOrDefault(card => card.Definition.Id == item.Definition.Id) ?? item;
            var force = new CheckBox
            {
                Content = Localizer.Get("GameExtensions.ForceVersion"), IsChecked = current.ForceVersion,
            };
            var version = new TextBlock { Text = VersionDescription(current), TextWrapping = TextWrapping.Wrap };
            var error = new InfoBar
            {
                IsClosable = false, Severity = InfoBarSeverity.Error,
                Title = Localizer.Get("GameExtensions.SettingsError"),
                Message = Localizer.Get("GameExtensions.SettingsErrorBody"),
            };
            var content = new StackPanel { Spacing = 16, MaxWidth = 460 };
            content.Children.Add(new TextBlock { Text = Localizer.Get(item.Definition.DescriptionKey), TextWrapping = TextWrapping.Wrap });
            content.Children.Add(version);
            content.Children.Add(new TextBlock { Text = item.Definition.Id + " · " + item.Definition.Version });
            content.Children.Add(force);
            content.Children.Add(new TextBlock { Text = Localizer.Get("GameExtensions.ForceWarning"), TextWrapping = TextWrapping.Wrap });
            content.Children.Add(error);
            var dialog = new LightDismissContentDialog
            {
                XamlRoot = XamlRoot, RequestedTheme = ActualTheme,
                Title = Localizer.Format("GameExtensions.ConfigureTitle", Localizer.Get(item.Definition.TitleKey)),
                Content = content, DefaultButton = ContentDialogButton.None,
            };
            dialog.Closing += (_, args) => args.Cancel = applying;
            dialog.KeyDown += (_, args) =>
            {
                if (args.Key != Windows.System.VirtualKey.Escape) return;
                args.Handled = true;
                if (!applying) dialog.Hide();
            };
            // Click is user-only: reflecting a committed value does not trigger another write.
            force.Click += async (_, _) =>
            {
                if (applying) return;
                force.IsEnabled = false;
                error.IsOpen = false;
                try
                {
                    current = snapshot?.Cards.FirstOrDefault(card => card.Definition.Id == item.Definition.Id) ?? current;
                    var requestedForce = force.IsChecked == true;
                    var enabled = current.Enabled && (current.VersionMatches || requestedForce);
                    var saved = await SetEnabledAsync(current, enabled, requestedForce);
                    current = snapshot?.Cards.FirstOrDefault(card => card.Definition.Id == item.Definition.Id) ?? current;
                    force.IsChecked = current.ForceVersion;
                    version.Text = VersionDescription(current);
                    error.IsOpen = !saved;
                }
                finally { force.IsEnabled = true; }
            };
            await dialog.ShowAsync();
        }
        finally { dialogOpen = false; ApplyLatestView(); }
    }
    private async Task<bool> SetEnabledAsync(ExtensionCardView item, bool enabled, bool? forceVersion = null)
    {
        if (applying || App.Host is not { } host) return false;
        var saved = false;
        applying = true;
        foreach (var toggle in toggles.Values) toggle.IsEnabled = false;
        try
        {
            var view = await host.GameExtensions.SetPreferenceAsync(item.Definition.Id, enabled, forceVersion ?? item.ForceVersion, item.SettingsRevision);
            ErrorInfo.IsOpen = false;
            snapshot = view;
            saved = true;
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            ShowSettingsError();
            // A conflict never overwrites another client's settings. Re-read the committed state.
            try { snapshot = await host.GameExtensions.RefreshAsync(); }
            catch (Exception reload) when (reload is IOException or InvalidDataException or UnauthorizedAccessException) { }
        }
        finally
        {
            applying = false;
            if (snapshot is not null) Render(snapshot);
        }
        return saved;
    }

    private void ShowSettingsError()
    {
        ErrorInfo.Title = Localizer.Get("GameExtensions.SettingsError");
        ErrorInfo.Message = Localizer.Get("GameExtensions.SettingsErrorBody");
        ErrorInfo.IsOpen = true;
    }
}
