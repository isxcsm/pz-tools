using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using PzTools.Zomboid.Recovery;

namespace PzTools.App;

/// <summary>
/// The part of the revival dialog that asks where a dead character's belongings should come from. It
/// reads the save (without changing or locking it) for the zombies and corpses that may be theirs and
/// offers them, the one carrying most first and chosen, plus reviving without belongings. With nothing
/// found, it says so and the revival goes ahead without them, rather than refusing.
/// </summary>
internal sealed class RemainsQuestion(PzTools.App.Core.AppHost host, string saveId)
{
    private CancellationTokenSource? looking;
    private IReadOnlyList<RemainsCandidate> candidates = [];
    private RadioButtons? options;
    private string? fixedChoice;

    public StackPanel Panel { get; } = new() { Spacing = 8, Visibility = Visibility.Collapsed };

    /// <summary>False while looking: the revival needs the answer.</summary>
    public event Action<bool>? Ready;

    /// <summary>
    /// For the worker's --remains: a candidate's key, <see cref="CharacterRecoveryService.NoRemains"/>, or
    /// null when nothing needs choosing (alive, or carrying their things) or the save could not be read
    /// beforehand, in which case the worker looks again and uses the only candidate there is.
    /// </summary>
    public string? Choice => options is null ? fixedChoice
        : options.SelectedIndex >= 0 && options.SelectedIndex < candidates.Count
            ? candidates[options.SelectedIndex].Key : CharacterRecoveryService.NoRemains;

    public async void Look(long? playerId)
    {
        looking?.Cancel();
        var cancel = looking = new CancellationTokenSource();
        (candidates, options, fixedChoice) = ([], null, null);
        Panel.Children.Clear();
        Panel.Visibility = Visibility.Visible;
        var progress = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        progress.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        progress.Children.Add(Secondary(Localizer.Get("HealRemainsSearching")));
        Panel.Children.Add(progress);
        Ready?.Invoke(false);
        CharacterRecoveryPreview? preview;
        try
        {
            // Off the UI thread: a large world has thousands of map files to read.
            preview = await Task.Run(() => host.PreviewCharacterRecoveryAsync(saveId, playerId, cancel.Token), cancel.Token);
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested) { return; }
        catch (Exception) { preview = null; }
        if (cancel != looking) return;
        Panel.Children.Clear();
        Ready?.Invoke(true);
        if (preview is null) { Panel.Children.Add(Text(Localizer.Get("HealRemainsReadFailed"))); return; }
        if (!preview.SearchesRemains) { Panel.Visibility = Visibility.Collapsed; return; }
        if (preview.Candidates.Count == 0)
        {
            fixedChoice = CharacterRecoveryService.NoRemains;
            Panel.Children.Add(Text(Localizer.Get("HealRemainsNotFound")));
            return;
        }
        candidates = preview.Candidates.OrderByDescending(c => c.Items).ThenBy(c => c.Distance).ToArray();
        options = new RadioButtons();
        // Each option says what it does, then what it leaves in the world: taking the belongings removes
        // those remains, reviving without them leaves the remains carrying them.
        foreach (var candidate in candidates)
            options.Items.Add(Option(
                Localizer.Format(candidate.Kind == RemainsKind.Zombie ? "HealRemainsZombie" : "HealRemainsCorpse", candidate.Items),
                Localizer.Format(candidate.Kind == RemainsKind.Zombie ? "HealRemainsZombieEffect" : "HealRemainsCorpseEffect", candidate.Distance)));
        var kinds = candidates.Select(c => c.Kind).Distinct().ToArray();
        options.Items.Add(Option(Localizer.Get("HealRemainsNone"), Localizer.Get(kinds.Length > 1 ? "HealRemainsNoneMixed"
            : kinds[0] == RemainsKind.Zombie ? "HealRemainsNoneZombie" : "HealRemainsNoneCorpse")));
        options.SelectedIndex = 0;
        Panel.Children.Add(Text(Localizer.Get("HealRemainsChoose")));
        Panel.Children.Add(options);
    }

    public void Stop() { looking?.Cancel(); looking = null; }

    private static RadioButton Option(string title, string effect)
    {
        var content = new StackPanel { Spacing = 2 };
        content.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap });
        content.Children.Add(Secondary(effect));
        var option = new RadioButton { Content = content };
        AutomationProperties.SetName(option, title + ", " + effect);
        return option;
    }

    private static TextBlock Text(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };

    // The style, not the brush: a brush taken from the application's resources is the Windows theme's, while the
    // style's theme resource follows the theme the text is shown in (the app's own choice).
    private static TextBlock Secondary(string text) => new()
    {
        Text = text, FontSize = 12, Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
    };
}
