using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.App;

/// <summary>A stable, inline extension section. Runtime refreshes update values, never rebuild its controls.</summary>
internal sealed class ExtensionSettingsSection
{
    public SettingsExpander Control { get; }
    private readonly TextBlock title = Text();
    private readonly TextBlock description = Text();
    private readonly TextBlock statusTitle = Text();
    private readonly TextBlock version = Text();
    private readonly TextBlock status = Text();
    private readonly TextBlock lastSave = Text();
    private readonly TextBlock hint = Text();
    private readonly SettingToggle enabled;
    private readonly List<SettingRow> options = [];
    private readonly ExtensionDescriptor descriptor;

    /// <param name="save">Saves one edit: <see cref="GameExtensionSetting.Enabled"/>, <see cref="GameExtensionSetting.ForceVersion"/>
    /// or the key of one of the extension's own switches.</param>
    public ExtensionSettingsSection(string id, Func<string, bool, Task> save, bool initiallyExpanded = false)
    {
        descriptor = ExtensionDescriptors.For(id);
        enabled = new(value => save(GameExtensionSetting.Enabled, value));
        var details = new StackPanel { Spacing = 4 };
        foreach (var text in new[] { version, status, lastSave, hint }) details.Children.Add(text);
        Control = new SettingsExpander
        {
            Header = title, Description = description, Content = enabled.Control, IsExpanded = initiallyExpanded,
            // A plain glyph in the text colour, one per extension, so the sections tell apart at a glance.
            HeaderIcon = new FontIcon { Glyph = descriptor.Glyph, FontSize = 20 },
        };
        // The extension's own switches first, in its descriptor's order; then its status and the version override.
        foreach (var option in descriptor.Options) AddOption(option.Key, option.TitleKey, option.DescriptionKey, option);
        Control.Items.Add(new SettingsCard { Header = statusTitle, Description = details });
        AddOption(GameExtensionSetting.ForceVersion, "GameExtensions.ForceVersion", "GameExtensions.ForceWarning", null);
        Control.Loaded += CompleteInitialLayout;

        void AddOption(string setting, string titleKey, string descriptionKey, ExtensionOption? option)
        {
            var row = new SettingRow(option, titleKey, descriptionKey, value => save(setting, value));
            options.Add(row);
            Control.Items.Add(row.Card);
        }
    }

    private void CompleteInitialLayout(object sender, RoutedEventArgs args)
    {
        Control.Loaded -= CompleteInitialLayout;
        Control.UpdateLayout();
        SettingsExpanderLayout.CompleteInitialExpansion(Control);
        Control.UpdateLayout();
    }

    public void Update(GameExtensionsView view, ExtensionCardView card)
    {
        var activation = view.ActivationFor(card);
        var name = Localizer.Get(card.Definition.TitleKey);
        SetText(title, name);
        SetText(description, Localizer.Get(card.Definition.DescriptionKey));
        SetText(statusTitle, Localizer.Get("GameExtensions.CompatibilityStatus"));
        SetText(version, VersionDescription(card));
        SetText(status, activation.IsPerSave ? StatusText(card) : null);
        SetText(lastSave, ExecutionText(view.LastSave, card.Definition.Id));
        SetText(hint, ActivationHint(view, card, activation, descriptor));
        enabled.Update(activation.IsOn, activation.CanToggle, name);
        // The rows stay editable whatever the game does: they show and change the saved preference.
        foreach (var row in options) row.Update(row.Option is { } option ? card.Option(option) : card.ForceVersion);
    }

    private static string? ActivationHint(GameExtensionsView view, ExtensionCardView card, ExtensionActivationView activation,
        ExtensionDescriptor descriptor)
    {
        // The game's own version check (an ON saved while no game ran, then a game outside the range started)
        // has a hint of its own that says what to do; the generic failure would only send the player to the logs.
        if (activation.FailureReason == "version-mismatch") return Localizer.Get("GameExtensions.VersionMismatch");
        // An update of the app that waits for the game's restart: the sidebar's game-link card asks the same.
        if (activation.AwaitsGameRestart) return Localizer.Get("GameLinkCardRestartMessage");
        if (activation.FailureReason is not null) return Localizer.Get("GameExtensions.InitializationFailed");
        // Waiting for the module's own safe point: what the player can do about it is the module's to say.
        if (activation.IsBusy) return Localizer.Get(view.StatusOf(card.Definition.Id)?.Reason == "safe-boundary"
            ? descriptor.SafeBoundaryHintKey : "GameExtensions.Applying");
        if (card.Enabled && !view.RuntimeWorldReady) return Localizer.Get("GameExtensions.WorldRequired");
        if (!activation.IsPerSave && !card.CanEnable) return StatusText(card);
        if (activation.IsPerSave && !view.GameSavingEnabled)
            return Localizer.Get("GameSaveSetting.Header") + ": " + Localizer.Get("SettingDisabled");
        return null;
    }

    private static string VersionDescription(ExtensionCardView card)
    {
        var support = card.Definition.SupportedVersions ?? GameVersionSupport.All;
        var range = support.Scope == VersionSupportScope.All ? Localizer.Get("GameExtensions.VersionAll")
            : Localizer.Format(support.Scope == VersionSupportScope.Major ? "GameExtensions.VersionMajor" : "GameExtensions.VersionMinor", support.RangeText);
        return Localizer.Format("GameExtensions.VersionInfo", range, card.GameVersion ?? Localizer.Get("Unknown"));
    }

    private static string StatusText(ExtensionCardView card) => Localizer.Get(card.StatusCode switch
    {
        "version-mismatch" => "GameExtensions.VersionMismatch",
        "version-unknown" => "GameExtensions.VersionUnknown",
        "forced-version" => "GameExtensions.ForcedVersion",
        "disabled" => "GameExtensions.Disabled",
        _ => "GameExtensions.AwaitingValidation",
    });

    private static string? ExecutionText(RuntimeSaveExecution? save, string id) => save is null || save.RequestedProvider != id ? null
        : save.Outcome switch
        {
            RuntimeSaveOutcome.Running => Localizer.Get("GameExtensions.ExecutionRunning"),
            RuntimeSaveOutcome.Failed => Localizer.Format("GameExtensions.ExecutionFailed", save.Reason ?? "save-failed"),
            _ when save.Provider != id => Localizer.Format("GameExtensions.ExecutionFallback", save.Reason ?? "module-unavailable"),
            _ => Localizer.Get("GameExtensions.ExecutionSucceeded"),
        };

    private static TextBlock Text() => new() { TextWrapping = TextWrapping.Wrap };
    private static void SetText(TextBlock block, string? value)
    {
        var text = value ?? "";
        if (block.Text != text) block.Text = text;
        var visibility = value is null ? Visibility.Collapsed : Visibility.Visible;
        if (block.Visibility != visibility) block.Visibility = visibility;
    }

    private sealed class SettingRow
    {
        /// <summary>The extension's own switch this row shows; null for the version override.</summary>
        public ExtensionOption? Option { get; }
        public SettingsCard Card { get; }
        private readonly string titleKey, descriptionKey;
        private readonly TextBlock title = Text(), description = Text();
        private readonly SettingToggle editor;

        public SettingRow(ExtensionOption? option, string titleKey, string descriptionKey, Func<bool, Task> save)
        {
            Option = option;
            this.titleKey = titleKey; this.descriptionKey = descriptionKey;
            editor = new(save);
            Card = new SettingsCard { Header = title, Description = description, Content = editor.Control };
        }

        public void Update(bool value)
        {
            var name = Localizer.Get(titleKey);
            SetText(title, name);
            SetText(description, Localizer.Get(descriptionKey));
            editor.Update(value, canEdit: true, name);
        }
    }

    internal sealed class SettingToggle
    {
        public ToggleSwitch Control { get; } = new();
        private bool reflecting, savedValue;
        private int pendingWrites;

        public SettingToggle(Func<bool, Task> save)
        {
            Control.Toggled += async (_, _) =>
            {
                if (reflecting) return;
                var requested = Control.IsOn;
                pendingWrites++;
                try { await save(requested); }
                finally { pendingWrites--; ReflectSavedValue(); }
            };
        }

        public void Update(bool value, bool canEdit, string name)
        {
            savedValue = value;
            if (Control.IsEnabled != canEdit) Control.IsEnabled = canEdit;
            if (!Equals(Control.OnContent, Localizer.Get("SettingEnabled"))) Control.OnContent = Localizer.Get("SettingEnabled");
            if (!Equals(Control.OffContent, Localizer.Get("SettingDisabled"))) Control.OffContent = Localizer.Get("SettingDisabled");
            if (AutomationProperties.GetName(Control) != name) AutomationProperties.SetName(Control, name);
            ReflectSavedValue();
        }

        private void ReflectSavedValue()
        {
            // Keep the latest visible user intent while queued writes commit. Runtime refreshes
            // still update savedValue, so success or failure settles to the newest committed value.
            if (pendingWrites != 0 || Control.IsOn == savedValue) return;
            reflecting = true;
            try { Control.IsOn = savedValue; }
            finally { reflecting = false; }
        }
    }
}
