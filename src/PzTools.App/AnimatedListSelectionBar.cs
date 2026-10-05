using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace PzTools.App;

/// <summary>Moves a list's selection indicator with the same composition stretch and shrink as NavigationView.</summary>
internal sealed class AnimatedListSelectionBar
{
    // NavigationView uses 600 ms: stretch to the far edge in the first 200 ms,
    // then let the trailing edge catch up over the remaining 400 ms.
    private static readonly TimeSpan AnimationDuration = TimeSpan.FromMilliseconds(600);
    private const float StretchKeyFrame = 1f / 3f;
    private readonly ListView list;
    private readonly Canvas surface;
    private readonly Border bar;
    private readonly double verticalInset;
    private object? lastSelection;
    private double lastTop = double.NaN;
    private double lastHeight = double.NaN;
    private Vector3KeyFrameAnimation? translationAnimation;
    private Vector3KeyFrameAnimation? scaleAnimation;
    private int animationVersion;
    private bool scrollHooked;

    public AnimatedListSelectionBar(
        ListView list, Canvas surface, Border bar, double verticalInset)
    {
        this.list = list;
        this.surface = surface;
        this.bar = bar;
        this.verticalInset = verticalInset;
        list.SelectionChanged += (_, _) =>
        {
            Update();
            list.DispatcherQueue.Enqueue(() => { if (!unloaded) Update(); });
        };
        list.Loaded += (_, _) =>
        {
            unloaded = false;
            if (!scrollHooked) scrollHooked = HookScrollViewer(list);
            Update();
        };
        // Closing the window unloads the list and then runs what is still queued: by then the list is torn down,
        // and reading it fails with E_UNEXPECTED, which ends the process on the way out.
        list.Unloaded += (_, _) => unloaded = true;
        // LayoutUpdated fires for every layout pass anywhere in the window (a countdown tick, a
        // progress card), several times a frame. One follow-up per dispatcher turn is enough to catch
        // a selected row that moved; selection and scrolling still update at once.
        list.LayoutUpdated += (_, _) =>
        {
            if (layoutQueued || unloaded) return;
            layoutQueued = list.DispatcherQueue.Enqueue(
                Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => { layoutQueued = false; if (!unloaded) Update(); });
        };
        surface.SizeChanged += (_, _) => Update();
    }

    private bool layoutQueued, unloaded;

    private void Update()
    {
        if (!list.IsLoaded || surface.ActualHeight <= 0) return;
        var selection = list.SelectedItem;
        var container = selection is null ? null : list.ContainerFromItem(selection) as ListViewItem;
        if (container is null || container.ActualHeight <= 0)
        {
            ResetAnimation();
            bar.Visibility = Visibility.Collapsed;
            if (selection is null)
            {
                lastSelection = null;
                lastTop = double.NaN;
            }
            return;
        }

        var point = container.TransformToVisual(surface).TransformPoint(new Point(0, 0));
        var height = Math.Max(12, container.ActualHeight - 2 * verticalInset);
        var top = point.Y + (container.ActualHeight - height) / 2;
        if (top + height <= 0 || top >= surface.ActualHeight)
        {
            ResetAnimation();
            bar.Visibility = Visibility.Collapsed;
            return;
        }
        if (ReferenceEquals(selection, lastSelection)
            && Math.Abs(top - lastTop) < 0.5
            && Math.Abs(height - lastHeight) < 0.5)
            return;

        var animate = bar.Visibility == Visibility.Visible
            && lastSelection is not null
            && !ReferenceEquals(selection, lastSelection)
            && !double.IsNaN(lastTop)
            && Math.Abs(lastTop - top) >= 0.5;
        var previousTop = lastTop;
        var previousHeight = lastHeight;
        ResetAnimation();
        lastSelection = selection;
        lastTop = top;
        lastHeight = height;
        Canvas.SetTop(bar, top);
        bar.Height = height;
        bar.Visibility = Visibility.Visible;
        if (!animate) return;

        // Settle the new bar's layout position first, then animate the move relative to it.
        surface.UpdateLayout();
        var compositor = CompositionTarget.GetCompositorForCurrentThread();
        var batch = compositor.CreateScopedBatch(CompositionBatchTypes.Animation);
        (translationAnimation, scaleAnimation) = StartStretch(bar, previousTop, previousHeight, top, height, horizontal: false);
        var version = animationVersion;
        batch.Completed += (_, _) =>
        {
            if (version == animationVersion) ResetAnimation();
        };
        batch.End();
    }

    /// <summary>
    /// Moves an indicator from its previous place to where layout has already put it: the leading edge
    /// arrives first and the trailing edge follows, along the vertical or the horizontal axis.
    /// </summary>
    internal static (Vector3KeyFrameAnimation Translation, Vector3KeyFrameAnimation Scale) StartStretch(
        UIElement indicator, double from, double fromSize, double to, double toSize, bool horizontal)
    {
        var compositor = CompositionTarget.GetCompositorForCurrentThread();
        var forward = from < to;
        var fromTranslation = (float)(from - to);
        var stretchEase = compositor.CreateCubicBezierEasingFunction(
            new Vector2(0.9f, 0.1f), new Vector2(1f, 0.2f));
        var settleEase = compositor.CreateCubicBezierEasingFunction(
            new Vector2(0.1f, 0.9f), new Vector2(0.2f, 1f));
        Vector3 Along(float value, float rest) => horizontal ? new Vector3(value, rest, rest == 0 ? 0 : 1) : new Vector3(rest, value, rest == 0 ? 0 : 1);

        // One bar: its leading end arrives first and its trailing end follows.
        // Two bars drawn apart would look like two selected items during the move.
        var stretchedSize = forward
            ? to + toSize - from
            : from + fromSize - to;
        // The Canvas coordinates are already the new item's position. Absolute coordinates put back into
        // Visual.Offset, which XAML layout owns, would apply it twice, so only the relative move is animated.
        var translation = compositor.CreateVector3KeyFrameAnimation();
        translation.Target = "Translation";
        translation.InsertKeyFrame(0, Along(fromTranslation, 0));
        translation.InsertKeyFrame(StretchKeyFrame, Along(forward ? fromTranslation : 0, 0), stretchEase);
        translation.InsertKeyFrame(1, Vector3.Zero, settleEase);
        translation.Duration = AnimationDuration;

        var scale = compositor.CreateVector3KeyFrameAnimation();
        scale.Target = "Scale";
        scale.InsertKeyFrame(0, Along((float)(fromSize / toSize), 1));
        scale.InsertKeyFrame(StretchKeyFrame, Along((float)(stretchedSize / toSize), 1), stretchEase);
        scale.InsertKeyFrame(1, Vector3.One, settleEase);
        scale.Duration = AnimationDuration;

        indicator.StartAnimation(translation);
        indicator.StartAnimation(scale);
        return (translation, scale);
    }
    private void ResetAnimation()
    {
        animationVersion++;
        if (translationAnimation is not null)
        {
            bar.StopAnimation(translationAnimation);
            translationAnimation = null;
        }
        if (scaleAnimation is not null)
        {
            bar.StopAnimation(scaleAnimation);
            scaleAnimation = null;
        }
        bar.Translation = Vector3.Zero;
        bar.Scale = Vector3.One;
    }

    private bool HookScrollViewer(DependencyObject root)
    {
        if (root is ScrollViewer scroll)
        {
            scroll.ViewChanged += (_, _) => Update();
            return true;
        }
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
            if (HookScrollViewer(VisualTreeHelper.GetChild(root, index))) return true;
        return false;
    }
}
