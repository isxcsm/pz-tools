using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using PzTools.GameExtensions;

namespace PzTools.App;

/// <summary>
/// The screen look extension's own options: a mood, a strength and the seasonal colours. The
/// extension's switch, status and version rule are the section's, as for every extension; this
/// only adds the rows that are particular to it. Controls are kept across refreshes.
/// </summary>
internal sealed class ScreenLookOptions
{
    public IReadOnlyList<SettingsCard> Cards { get; }
    private readonly TextBlock presetTitle = Text(), presetDescription = Text();
    private readonly TextBlock strengthTitle = Text(), strengthDescription = Text();
    private readonly TextBlock strengthValue = new() { MinWidth = 44, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock seasonalTitle = Text(), seasonalDescription = Text();
    private readonly ExtensionSettingsSection.SettingToggle seasonal;
    private readonly ComboBox preset = new() { MinWidth = 168 };
    private readonly Slider strength = new() { Minimum = 0, Maximum = 100, StepFrequency = 5, SmallChange = 5, LargeChange = 20, Width = 200 };
    // Dragging reports every step; only where the thumb comes to rest is saved.
    private readonly DispatcherTimer strengthSettled = new() { Interval = TimeSpan.FromMilliseconds(350) };
    private readonly Func<Func<ScreenLookPreference, ScreenLookPreference>, Task> save;
    private bool reflecting;
    private int pendingWrites;
    private ScreenLookPreference saved = new();
    private string language = "";

    public ScreenLookOptions(Func<Func<ScreenLookPreference, ScreenLookPreference>, Task> save)
    {
        this.save = save;
        seasonal = new(value => save(current => current with { Seasonal = value }));
        var strengthEditor = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        strengthEditor.Children.Add(strength);
        strengthEditor.Children.Add(strengthValue);
        Cards =
        [
            new SettingsCard { Header = presetTitle, Description = presetDescription, Content = preset },
            new SettingsCard { Header = strengthTitle, Description = strengthDescription, Content = strengthEditor },
            new SettingsCard { Header = seasonalTitle, Description = seasonalDescription, Content = seasonal.Control },
        ];

        preset.SelectionChanged += async (_, _) =>
        {
            if (reflecting || preset.SelectedIndex < 0) return;
            var chosen = ScreenLookPreference.Presets[preset.SelectedIndex];
            await SaveAsync(current => current with { Preset = chosen });
        };
        strength.ValueChanged += (_, _) =>
        {
            ShowStrength((int)Math.Round(strength.Value));
            if (reflecting) return;
            strengthSettled.Stop();
            strengthSettled.Start();
        };
        strengthSettled.Tick += async (_, _) =>
        {
            strengthSettled.Stop();
            var chosen = (int)Math.Round(strength.Value);
            if (chosen != saved.Strength) await SaveAsync(current => current with { Strength = chosen });
        };
    }

    private async Task SaveAsync(Func<ScreenLookPreference, ScreenLookPreference> change)
    {
        pendingWrites++;
        try { await save(change); }
        finally { pendingWrites--; Reflect(); }
    }

    public void Update(ScreenLookPreference preference, bool canEdit)
    {
        saved = preference;
        SetText(presetTitle, Localizer.Get("ScreenLook.Preset"));
        SetText(presetDescription, Localizer.Get("ScreenLook.PresetDescription"));
        SetText(strengthTitle, Localizer.Get("ScreenLook.Strength"));
        SetText(strengthDescription, Localizer.Get("ScreenLook.StrengthDescription"));
        SetText(seasonalTitle, Localizer.Get("ScreenLook.Seasonal"));
        SetText(seasonalDescription, Localizer.Get("ScreenLook.SeasonalDescription"));
        if (language != Localizer.Culture.Name)
        {
            // Mood names are the only text held by a control; rebuild them when the language changes.
            language = Localizer.Culture.Name;
            reflecting = true;
            try
            {
                preset.ItemsSource = new[]
                {
                    Localizer.Get("ScreenLook.PresetRealistic"), Localizer.Get("ScreenLook.PresetVivid"),
                    Localizer.Get("ScreenLook.PresetCinematic"),
                };
            }
            finally { reflecting = false; }
        }
        AutomationProperties.SetName(preset, Localizer.Get("ScreenLook.Preset"));
        AutomationProperties.SetName(strength, Localizer.Get("ScreenLook.Strength"));
        seasonal.Update(saved.Seasonal, canEdit, Localizer.Get("ScreenLook.Seasonal"));
        if (preset.IsEnabled != canEdit) preset.IsEnabled = canEdit;
        if (strength.IsEnabled != canEdit) strength.IsEnabled = canEdit;
        Reflect();
    }

    private void Reflect()
    {
        // While a write is queued or the thumb is still moving, the control shows what the user is doing.
        if (pendingWrites != 0 || strengthSettled.IsEnabled) return;
        reflecting = true;
        try
        {
            var index = ScreenLookPreference.Presets.ToList().IndexOf(saved.Preset);
            if (preset.SelectedIndex != index) preset.SelectedIndex = index;
            if ((int)Math.Round(strength.Value) != saved.Strength) strength.Value = saved.Strength;
        }
        finally { reflecting = false; }
        ShowStrength(saved.Strength);
    }

    private void ShowStrength(int value)
    {
        var text = Localizer.Format("ScreenLook.StrengthValue", value);
        if (strengthValue.Text != text) strengthValue.Text = text;
    }

    private static TextBlock Text() => new() { TextWrapping = TextWrapping.Wrap };
    private static void SetText(TextBlock block, string? value)
    {
        var text = value ?? "";
        if (block.Text != text) block.Text = text;
    }
}
