using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace PzTools.App;

/// <summary>
/// The underline of a <see cref="SelectorBar"/>, moved between tabs with the same stretch as the list
/// selection bars instead of jumping. Each tab's own underline is hidden, so there is only ever one.
/// </summary>
internal sealed class AnimatedSelectorBarIndicator
{
    private readonly SelectorBar tabs;
    private readonly Canvas surface;
    private readonly Border indicator;
    private readonly HashSet<SelectorBarItem> quieted = [];
    private SelectorBarItem? lastItem;
    private double lastLeft = double.NaN, lastTop = double.NaN;

    public AnimatedSelectorBarIndicator(SelectorBar tabs, Canvas surface, Border indicator)
    {
        this.tabs = tabs;
        this.surface = surface;
        this.indicator = indicator;
        tabs.SelectionChanged += (_, _) => Update();
        // A tab's text changes width with the language, and the tabs appear only with a recording.
        // LayoutUpdated fires for every layout pass in the window, so it is followed once per turn.
        tabs.LayoutUpdated += (_, _) =>
        {
            if (layoutQueued || unloaded) return;
            layoutQueued = tabs.DispatcherQueue.Enqueue(
                Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => { layoutQueued = false; if (!unloaded) Update(); });
        };
        // Closing the window unloads the tabs and then runs what is still queued: by then the tabs are torn down,
        // and reading them fails with E_UNEXPECTED, which ends the process on the way out.
        tabs.Loaded += (_, _) => unloaded = false;
        tabs.Unloaded += (_, _) => unloaded = true;
        surface.SizeChanged += (_, _) => Update();
    }

    private bool layoutQueued, unloaded;

    private void Update()
    {
        foreach (var tab in tabs.Items)
            if (!quieted.Contains(tab) && Find(tab, "PART_SelectionVisual") is UIElement own)
            {
                // The template only fades it in and out; hidden, it stays hidden in every state.
                own.Visibility = Visibility.Collapsed;
                quieted.Add(tab);
            }
        if (!tabs.IsLoaded || tabs.SelectedItem is not { } item || item.ActualWidth <= 0 || surface.ActualHeight <= 0)
        {
            indicator.Visibility = Visibility.Collapsed;
            return;
        }
        var point = item.TransformToVisual(surface).TransformPoint(new Point(0, 0));
        var width = indicator.Width;
        var left = point.X + (item.ActualWidth - width) / 2;
        var top = point.Y + item.ActualHeight - indicator.Height;
        if (ReferenceEquals(item, lastItem) && Math.Abs(left - lastLeft) < 0.5 && Math.Abs(top - lastTop) < 0.5
            && indicator.Visibility == Visibility.Visible)
            return;
        var animate = SystemMotion.Enabled && indicator.Visibility == Visibility.Visible && lastItem is not null
            && !ReferenceEquals(item, lastItem) && Math.Abs(lastLeft - left) >= 0.5;
        var previousLeft = lastLeft;
        lastItem = item;
        lastLeft = left;
        lastTop = top;
        Canvas.SetLeft(indicator, left);
        Canvas.SetTop(indicator, top);
        indicator.Visibility = Visibility.Visible;
        if (!animate) return;
        surface.UpdateLayout();
        AnimatedListSelectionBar.StartStretch(indicator, previousLeft, width, left, width, horizontal: true);
    }

    private static DependencyObject? Find(DependencyObject root, string name)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            if (child is FrameworkElement { Name: var found } && found == name) return child;
            if (Find(child, name) is { } deeper) return deeper;
        }
        return null;
    }
}
