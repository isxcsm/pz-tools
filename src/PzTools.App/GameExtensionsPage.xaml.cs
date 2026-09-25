using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using PzTools.App.Core;
using PzTools.GameExtensions;

namespace PzTools.App;

public sealed partial class GameExtensionsPage : UserControl
{
    private GameExtensionsView? snapshot;
    private bool refreshing;
    private bool applying;
    private readonly Dictionary<string, ToggleSwitch> toggles = new(StringComparer.Ordinal);
    private App App => (App)Application.Current;

    public GameExtensionsPage()
    {
        InitializeComponent();
        ApplyLocalizedText();
        Loaded += async (_, _) => await RefreshForNavigationAsync();
    }

    internal void ApplyLocalizedText()
    {
        Language = Localizer.Culture.Name;
        PageTitle.Text = Localizer.Get("GameExtensions.Title");
        PageDescription.Text = Localizer.Get("GameExtensions.Description");
        ErrorInfo.Title = Localizer.Get("GameExtensions.SettingsError");
        if (snapshot is not null) Render(snapshot);
    }

    internal async Task RefreshForNavigationAsync()
    {
        if (refreshing || applying) return;
        var host = App.Host;
        if (host is null) return;
        refreshing = true;
        Loading.Visibility = snapshot is null ? Visibility.Visible : Visibility.Collapsed;
        Loading.IsActive = snapshot is null;
        try { Render(await host.GameExtensions.RefreshAsync()); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        { ShowSettingsError(); }
        finally { refreshing = false; Loading.IsActive = false; Loading.Visibility = Visibility.Collapsed; }
    }

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
                Text = Localizer.Get(item.Enabled ? "GameExtensions.AwaitingValidation" : "GameExtensions.Disabled"),
                TextWrapping = TextWrapping.Wrap,
            });
            var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            var configure = new Button { Content = Localizer.Get("GameExtensions.Configure"), IsEnabled = !applying };
            configure.Click += async (_, _) => await ConfigureAsync(item);
            AutomationProperties.SetName(configure, Localizer.Format("GameExtensions.ConfigureTitle", Localizer.Get(item.Definition.TitleKey)));
            var toggle = new ToggleSwitch
            {
                IsOn = item.Enabled, IsEnabled = !applying,
                OnContent = Localizer.Get("SettingEnabled"), OffContent = Localizer.Get("SettingDisabled"),
            };
            AutomationProperties.SetName(toggle, Localizer.Get(item.Definition.TitleKey));
            toggle.Toggled += async (_, _) => await SetEnabledAsync(item, toggle.IsOn);
            toggles[item.Definition.Id] = toggle;
            controls.Children.Add(configure);
            controls.Children.Add(toggle);
            Cards.Children.Add(new SettingsCard
            {
                Header = Localizer.Get(item.Definition.TitleKey), Description = description,
                HeaderIcon = new SymbolIcon(Symbol.Repair), Content = controls,
            });
        }
    }

    private async Task ConfigureAsync(ExtensionCardView item)
    {
        if (applying) return;
        // v0.1 exposes only the implemented lifecycle preference, not pretend tuning options.
        var enabled = new ToggleSwitch
        {
            Header = Localizer.Get(item.Definition.TitleKey), IsOn = item.Enabled,
            OnContent = Localizer.Get("SettingEnabled"), OffContent = Localizer.Get("SettingDisabled"),
        };
        var content = new StackPanel { Spacing = 16, MaxWidth = 460 };
        content.Children.Add(new TextBlock { Text = Localizer.Get("GameExtensions.ValidationNotice"), TextWrapping = TextWrapping.Wrap });
        content.Children.Add(new TextBlock { Text = item.Definition.Id + " · " + item.Definition.Version });
        content.Children.Add(enabled);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, RequestedTheme = ActualTheme,
            Title = Localizer.Format("GameExtensions.ConfigureTitle", Localizer.Get(item.Definition.TitleKey)),
            Content = content, PrimaryButtonText = Localizer.Get("GameExtensions.Apply"),
            CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && enabled.IsOn != item.Enabled)
            await SetEnabledAsync(item, enabled.IsOn);
    }

    private async Task SetEnabledAsync(ExtensionCardView item, bool enabled)
    {
        if (applying || App.Host is not { } host) return;
        applying = true;
        foreach (var toggle in toggles.Values) toggle.IsEnabled = false;
        try
        {
            var view = await host.GameExtensions.SetEnabledAsync(item.Definition.Id, enabled, item.SettingsRevision);
            ErrorInfo.IsOpen = false;
            snapshot = view;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            ShowSettingsError();
            // A conflict never overwrites another client's settings. Re-read the committed state.
            try { snapshot = await host.GameExtensions.RefreshAsync(); }
            catch (Exception reload) when (reload is IOException or UnauthorizedAccessException) { }
        }
        finally
        {
            applying = false;
            if (snapshot is not null) Render(snapshot);
        }
    }

    private void ShowSettingsError()
    {
        ErrorInfo.Title = Localizer.Get("GameExtensions.SettingsError");
        ErrorInfo.Message = Localizer.Get("GameExtensions.SettingsErrorBody");
        ErrorInfo.IsOpen = true;
    }
}
