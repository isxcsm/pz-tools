using Microsoft.UI.Xaml;

namespace PzTools.App;

public sealed partial class MainWindowShell
{
    private const double CountdownDimmedOpacity = 0.35;
    private bool? countdownSuspended;

    // A held countdown blinks: one step per tick of the one-second countdown timer. A composition
    // animation did the same with a step easing, but the compositor still evaluated it on every
    // display refresh, about 3% of a core for as long as the game stayed paused (measured).
    private void UpdateCountdownPulse(bool suspended, bool visible, bool tick)
    {
        if (countdownSuspended != suspended)
        {
            countdownSuspended = suspended;
            NextBackupRemainingText.Style = (Style)(suspended
                ? Resources["SuspendedCountdownTextStyle"] : Application.Current.Resources["SecondaryTextStyle"]);
        }
        // The tick also applies changes to the reduced-motion preference.
        if (!suspended || !visible || !IsLoaded || !navigationUiSettings.AnimationsEnabled)
        {
            StopCountdownPulse();
            return;
        }
        // Refreshes between ticks leave the blink where it is.
        if (tick) NextBackupRemainingText.Opacity = NextBackupRemainingText.Opacity == 1 ? CountdownDimmedOpacity : 1;
    }

    private void StopCountdownPulse()
    {
        if (NextBackupRemainingText.Opacity != 1) NextBackupRemainingText.Opacity = 1;
    }
}
