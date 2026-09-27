using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
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
    private readonly TextBlock version = Text();
    private readonly TextBlock status = Text();
    private readonly TextBlock lastSave = Text();
    private readonly TextBlock hint = Text();
    private readonly SettingToggle enabled;
    private readonly List<SettingRow> options = [];

    public ExtensionSettingsSection(string id, Func<GameExtensionSetting, bool, Task> save)
    {
        enabled = new(value => save(GameExtensionSetting.Enabled, value));
        var details = new StackPanel { Spacing = 4 };
        foreach (var text in new[] { description, version, status, lastSave, hint }) details.Children.Add(text);
        Control = new SettingsExpander
        {
            Header = title, Description = details, Content = enabled.Control, IsExpanded = false,
            HeaderIcon = new ImageIcon
            {
                Width = 20, Height = 20,
                Source = new SvgImageSource(new Uri("ms-appx:///Assets/Navigation/extensions.svg")),
            },
        };
        if (id == ExtensionIds.VehicleDrivetrain)
        {
            AddOption(GameExtensionSetting.Torque, "VehicleDrivetrain.Torque", "VehicleDrivetrain.TorqueDescription");
            AddOption(GameExtensionSetting.Reverse, "VehicleDrivetrain.Reverse", "VehicleDrivetrain.ReverseDescription");
            AddOption(GameExtensionSetting.Steering, "VehicleDrivetrain.Steering", "VehicleDrivetrain.SteeringDescription");
        }
        AddOption(GameExtensionSetting.ForceVersion, "GameExtensions.ForceVersion", "GameExtensions.ForceWarning");

        void AddOption(GameExtensionSetting setting, string titleKey, string descriptionKey)
        {
            var row = new SettingRow(setting, titleKey, descriptionKey, value => save(setting, value));
            options.Add(row);
            Control.Items.Add(row.Card);
        }
    }

    public void Update(GameExtensionsView view, ExtensionCardView card)
    {
        var activation = view.ActivationFor(card);
        var name = Localizer.Get(card.Definition.TitleKey);
        SetText(title, name);
        SetText(description, Localizer.Get(card.Definition.DescriptionKey));
        SetText(version, VersionDescription(card));
        SetText(status, activation.IsPerSave ? StatusText(card) : null);
        SetText(lastSave, ExecutionText(view.LastSave, card.Definition.Id));
        SetText(hint, ActivationHint(view, card, activation));
        enabled.Update(activation.IsOn, activation.CanToggle, name);
        var preference = card.VehicleDrivetrain ?? new VehicleDrivetrainPreference();
        foreach (var row in options)
        {
            bool value = row.Setting switch
            {
                GameExtensionSetting.ForceVersion => card.ForceVersion,
                GameExtensionSetting.Torque => preference.TorqueEnabled,
                GameExtensionSetting.Reverse => preference.ReverseEnabled,
                GameExtensionSetting.Steering => preference.SteeringEnabled,
                _ => throw new InvalidOperationException("Unknown extension setting row."),
            };
            row.Update(value, activation.CanEditOptions);
        }
    }

    private static string? ActivationHint(GameExtensionsView view, ExtensionCardView card, ExtensionActivationView activation)
    {
        if (activation.FailureReason is not null) return Localizer.Get("GameExtensions.InitializationFailed");
        if (activation.IsBusy) return Localizer.Get(view.VehicleStatus?.Reason == "safe-boundary"
            ? "GameExtensions.ApplyWhenSafe" : "GameExtensions.Applying");
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
        public GameExtensionSetting Setting { get; }
        public SettingsCard Card { get; }
        private readonly string titleKey, descriptionKey;
        private readonly TextBlock title = Text(), description = Text();
        private readonly SettingToggle editor;

        public SettingRow(GameExtensionSetting setting, string titleKey, string descriptionKey, Func<bool, Task> save)
        {
            Setting = setting;
            this.titleKey = titleKey; this.descriptionKey = descriptionKey;
            editor = new(save);
            Card = new SettingsCard { Header = title, Description = description, Content = editor.Control };
        }

        public void Update(bool value, bool canEdit)
        {
            var name = Localizer.Get(titleKey);
            SetText(title, name);
            SetText(description, Localizer.Get(descriptionKey));
            editor.Update(value, canEdit, name);
        }
    }

    private sealed class SettingToggle
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
