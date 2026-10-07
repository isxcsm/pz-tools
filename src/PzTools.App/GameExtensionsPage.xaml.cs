using System.Collections.ObjectModel;
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using PzTools.App.Core;

namespace PzTools.App;

public sealed partial class GameExtensionsPage : UserControl
{
    private GameExtensionsView? snapshot;
    private bool refreshing;
    private IDisposable? subscription;
    private long viewRevision;
    private readonly Dictionary<string, ExtensionSettingsSection> sections = new(StringComparer.Ordinal);
    public ObservableCollection<SettingsExpander> Sections { get; } = [];
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
                if (key == GameExtensionController.ViewKey) DispatcherQueue.Enqueue(ApplyLatestView);
            });
            if (App.StartupLoader is { } loader)
            {
                loader.Changed -= StartupLoaderChanged;
                loader.Changed += StartupLoaderChanged;
                ApplyStartupLoader();
                _ = RefreshStartupLoaderAsync(loader);
            }
            await RefreshForNavigationAsync();
        };
        Unloaded += (_, _) =>
        {
            subscription?.Dispose();
            subscription = null;
            if (App.StartupLoader is { } loader) loader.Changed -= StartupLoaderChanged;
        };
    }

    internal void ApplyLocalizedText()
    {
        Language = Localizer.Culture.Name;
        PageTitle.Text = Localizer.Get("GameExtensions.Title");
        ApplyStartupLoader();
        if (snapshot is not null) UpdateView(snapshot);
    }

    // ---- The startup loader (hidden unless the advanced setting turns it on) ----

    private bool changingStartupLoader;

    private void StartupLoaderChanged() => DispatcherQueue.TryEnqueue(ApplyStartupLoader);

    // Called from the Loaded handler without being awaited: nothing may escape it.
    private async Task RefreshStartupLoaderAsync(StartupLoader loader)
    {
        try { await loader.RefreshAsync(); }
        catch (Exception exception) { System.Diagnostics.Debug.WriteLine(exception); }
    }

    private void ApplyStartupLoader()
    {
        if (App.StartupLoader is not { } loader) { StartupLoaderCard.Visibility = Visibility.Collapsed; return; }
        var status = loader.State.Status;
        StartupLoaderCard.Visibility = Visibility.Visible;
        StartupLoaderCard.Header = Localizer.Get("StartupLoaderHeader");
        var description = Localizer.Get(status switch
        {
            StartupLoaderStatus.NotFound => "StartupLoaderNotFound",
            StartupLoaderStatus.NotInstalled => "StartupLoaderNotInstalled",
            StartupLoaderStatus.Installed => "StartupLoaderInstalled",
            StartupLoaderStatus.Reverted => "StartupLoaderReverted",
            StartupLoaderStatus.Foreign => "StartupLoaderForeign",
            _ => "StartupLoaderChecking",
        });
        StartupLoaderCard.Description = StartupGameText(loader.State.Game) is { } game ? description + "\n" + game : description;
        StartupLoaderSwitch.OnContent = Localizer.Get("SettingEnabled");
        StartupLoaderSwitch.OffContent = Localizer.Get("SettingDisabled");
        AutomationProperties.SetName(StartupLoaderSwitch, Localizer.Get("StartupLoaderHeader"));
        // While a change runs, the switch keeps the position the player gave it; then it shows what the jar is.
        if (!changingStartupLoader) ReflectStartupLoader(status == StartupLoaderStatus.Installed);
        StartupLoaderSwitch.IsEnabled = !changingStartupLoader
            && status is StartupLoaderStatus.NotInstalled or StartupLoaderStatus.Installed or StartupLoaderStatus.Reverted;
    }

    /// <summary>What to say about the game that runs now: it started without the loader, the loader did not load, or
    /// some of the extension API's hooks did not go in. Null when all is well or nothing is known.</summary>
    internal static string? StartupGameText(StartupGameReport? game) => game switch
    {
        null or { HasProblem: false } => null,
        { Status: StartupGameStatus.StartedWithout } => Localizer.Get("StartupLoaderGameWithout"),
        { Status: StartupGameStatus.LoadFailed } => Localizer.Get("StartupLoaderGameFailed"),
        _ => Localizer.Format("StartupLoaderHooksMissing", string.Join(", ", game.MissingHookNames)),
    };

    private bool reflectingStartupLoader;

    private void ReflectStartupLoader(bool installed)
    {
        if (StartupLoaderSwitch.IsOn == installed) return;
        reflectingStartupLoader = true;
        try { StartupLoaderSwitch.IsOn = installed; }
        finally { reflectingStartupLoader = false; }
    }

    // The switch is turned off while the jar changes; the change has its own card in the sidebar.
    private async void StartupLoaderSwitch_Toggled(object sender, RoutedEventArgs e)
    {
        if (reflectingStartupLoader || changingStartupLoader || App.StartupLoader is not { } loader) return;
        if (App.MainWindow.Content is not MainWindowShell shell) { ApplyStartupLoader(); return; }
        changingStartupLoader = true;
        ApplyStartupLoader();
        // An async event handler: nothing may escape it. The shell reports every failure on the card.
        try { await shell.ChangeStartupLoaderAsync(loader, StartupLoaderSwitch.IsOn); }
        catch (Exception exception) { System.Diagnostics.Debug.WriteLine(exception); }
        finally
        {
            changingStartupLoader = false;
            ApplyStartupLoader();
        }
    }

    internal async Task RefreshForNavigationAsync()
    {
        if (refreshing || App.Host is not { } host) return;
        refreshing = true;
        LoadingIndicator.Visibility = snapshot is null ? Visibility.Visible : Visibility.Collapsed;
        LoadingIndicator.IsActive = snapshot is null;
        try
        {
            await host.GameExtensions.RefreshAsync();
            ApplyLatestView();
        }
        // Called from the Loaded handler: nothing may escape it. Nothing was changed, so the card says why it could not
        // be read rather than that changes were lost.
        catch (Exception exception) { ShowSettingsError(UserFacingError.FromException(exception)); }
        finally { refreshing = false; LoadingIndicator.IsActive = false; LoadingIndicator.Visibility = Visibility.Collapsed; }
    }

    private void ApplyLatestView()
    {
        if (App.Host is not { } host) return;
        var changed = host.Views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, viewRevision);
        if (changed.Modified && changed.Snapshot is { } view)
        {
            viewRevision = changed.ViewRevision;
            UpdateView(view);
        }
    }

    private void UpdateView(GameExtensionsView view)
    {
        snapshot = view;
        var desired = new List<SettingsExpander>(view.Cards.Count);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var card in view.Cards)
        {
            var id = card.Definition.Id;
            ids.Add(id);
            if (!sections.TryGetValue(id, out var section))
            {
                section = new ExtensionSettingsSection(id, (setting, value) => SaveEditAsync(id, setting, value),
                    initiallyExpanded: view.Cards.Count == 1);
                sections.Add(id, section);
            }
            section.Update(view, card);
            desired.Add(section.Control);
        }
        // The same controls stay mounted through preference/runtime/localization updates.
        // Only catalogue insertion/removal/reordering changes the visual collection.
        IncrementalListReconciler.Reconcile(Sections, desired);
        foreach (var removed in sections.Keys.Where(id => !ids.Contains(id)).ToArray()) sections.Remove(removed);
    }

    private async Task SaveEditAsync(string id, GameExtensionSetting setting, bool value)
    {
        if (App.Host is not { } host) { ShowSettingsError(); return; }
        try
        {
            await host.GameExtensions.ApplyEditAsync(id, setting, value);
        }
        catch (Exception exception) when (IsSettingsError(exception))
        {
            ShowSettingsError();
            // A concurrent external writer may have won. Reflect committed data, never replay a stale snapshot.
            try { await host.GameExtensions.RefreshAsync(); }
            catch (Exception reload) when (IsSettingsError(reload)) { }
        }
        catch (Exception)
        {
            // Anything else (the host being replaced while the switch was saving, for one) is reported the
            // same way: a switch is driven by an async event handler, where an escaping exception ends the app.
            ShowSettingsError();
        }
        finally
        {
            // Read the revisioned store, not an async command's potentially older return value.
            ApplyLatestView();
        }
    }

    private static bool IsSettingsError(Exception exception) =>
        exception is IOException or InvalidDataException or UnauthorizedAccessException;

    // On a card with the user's other results, as every page reports them (docs/design/ui-ux-contract.md, "Operation
    // and result cards"); it is also kept in the logs. Without a message, it says the change was not saved.
    private void ShowSettingsError(string? message = null) =>
        App.ShowSidebarNotification(InfoBarSeverity.Error, Localizer.Get("GameExtensions.SettingsError"),
            message ?? Localizer.Get("GameExtensions.SettingsErrorBody"));
}
