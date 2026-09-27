using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;

namespace PzTools.App;

internal static class SettingsExpanderLayout
{
    public static void CompleteInitialExpansion(SettingsExpander section)
    {
        // The wrapper's native Expander starts a storyboard when its initial
        // state is applied. Finish that first state, not later user transitions.
        if (VisualTreeHelper.GetChildrenCount(section) == 0
            || VisualTreeHelper.GetChild(section, 0) is not Expander expander
            || VisualTreeHelper.GetChildrenCount(expander) == 0
            || VisualTreeHelper.GetChild(expander, 0) is not FrameworkElement root)
            return;
        foreach (var group in VisualStateManager.GetVisualStateGroups(root))
            if (group.Name == "ExpandStates" && group.CurrentState?.Storyboard is { } storyboard
                && storyboard.GetCurrentState() == ClockState.Active)
                storyboard.SkipToFill();
    }
}
