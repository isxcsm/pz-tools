using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace PzTools.App;

public sealed partial class MainWindowShell
{
    private ScalarKeyFrameAnimation? countdownPulse;
    private bool? countdownSuspended;

    private void UpdateCountdownPulse(bool suspended, bool visible)
    {
        if (countdownSuspended != suspended)
        {
            countdownSuspended = suspended;
            NextBackupRemainingText.Style = (Style)(suspended
                ? Resources["SuspendedCountdownTextStyle"] : Application.Current.Resources["SecondaryTextStyle"]);
        }
        // The existing one-second countdown tick also applies changes to reduced-motion
        // preferences. Do not restart the pulse on every observation or text refresh.
        if (!suspended || !visible || !IsLoaded || !navigationUiSettings.AnimationsEnabled)
        {
            StopCountdownPulse();
            return;
        }
        if (countdownPulse is not null) return;
        var compositor = CompositionTarget.GetCompositorForCurrentThread();
        countdownPulse = compositor.CreateScalarKeyFrameAnimation();
        countdownPulse.Target = "Opacity";
        // Hold each state for 650 ms, then switch instantly. No per-frame UI timer.
        var ease = compositor.CreateStepEasingFunction(1);
        ease.IsInitialStepSingleFrame = false;
        ease.IsFinalStepSingleFrame = true;
        countdownPulse.InsertKeyFrame(0, 1);
        countdownPulse.InsertKeyFrame(0.5f, 0.35f, ease);
        countdownPulse.InsertKeyFrame(1, 1, ease);
        countdownPulse.Duration = TimeSpan.FromMilliseconds(1300);
        countdownPulse.IterationBehavior = AnimationIterationBehavior.Forever;
        NextBackupRemainingText.StartAnimation(countdownPulse);
    }

    private void StopCountdownPulse()
    {
        if (countdownPulse is not null)
        {
            NextBackupRemainingText.StopAnimation(countdownPulse);
            countdownPulse.Dispose();
            countdownPulse = null;
        }
        NextBackupRemainingText.Opacity = 1;
    }
}
