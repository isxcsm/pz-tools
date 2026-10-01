using System.Collections.ObjectModel;
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
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
        ErrorInfo.Message = Localizer.Get("GameExtensions.SettingsErrorBody");
        if (snapshot is not null) UpdateView(snapshot);
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
        catch (Exception exception) when (IsSettingsError(exception)) { ShowSettingsError(); }
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
            ErrorInfo.IsOpen = false;
        }
        catch (Exception exception) when (IsSettingsError(exception))
        {
            ShowSettingsError();
            // A concurrent external writer may have won. Reflect committed data, never replay a stale snapshot.
            try { await host.GameExtensions.RefreshAsync(); }
            catch (Exception reload) when (IsSettingsError(reload)) { }
        }
        finally
        {
            // Read the revisioned store, not an async command's potentially older return value.
            ApplyLatestView();
        }
    }

    private static bool IsSettingsError(Exception exception) =>
        exception is IOException or InvalidDataException or UnauthorizedAccessException;

    private void ShowSettingsError()
    {
        ErrorInfo.Title = Localizer.Get("GameExtensions.SettingsError");
        ErrorInfo.Message = Localizer.Get("GameExtensions.SettingsErrorBody");
        ErrorInfo.IsOpen = true;
    }
}
