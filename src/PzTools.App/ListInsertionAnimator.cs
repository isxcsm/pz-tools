using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace PzTools.App;

/// <summary>Animates a contiguous insertion near the top without rebuilding existing rows.</summary>
internal sealed class ListInsertionAnimator(ListView list)
{
    private static readonly TimeSpan Duration = TimeSpan.FromMilliseconds(340);
    private readonly Dictionary<ListViewItem, CompositionAnimation[]> active = [];
    private int animationVersion;

    internal sealed record Snapshot<T>(T[] NewItems, Dictionary<T, double> PreviousY)
        where T : class;

    public Snapshot<T>? Capture<T>(IReadOnlyList<T> current, IReadOnlyList<T> desired,
        int insertionIndex) where T : class
    {
        // Without Windows' animation effects the rows simply appear: nothing to capture.
        if (!SystemMotion.Enabled || !list.IsLoaded || list.Visibility != Visibility.Visible
            || current.Count <= insertionIndex || desired.Count <= current.Count
            || FindScrollViewer(list)?.VerticalOffset > 2)
            return null;

        var inserted = desired.Count - current.Count;
        if (inserted > 4) return null;
        for (var index = 0; index < insertionIndex; index++)
            if (!ReferenceEquals(current[index], desired[index])) return null;
        for (var index = insertionIndex; index < current.Count; index++)
            if (!ReferenceEquals(current[index], desired[index + inserted])) return null;

        Reset();
        var previousY = new Dictionary<T, double>(ReferenceEqualityComparer.Instance);
        foreach (var item in current.Take(16))
        {
            if (list.ContainerFromItem(item) is not ListViewItem container
                || container.ActualHeight <= 0) continue;
            var y = container.TransformToVisual(list).TransformPoint(new Point(0, 0)).Y;
            if (y + container.ActualHeight > 0 && y < list.ActualHeight)
                previousY[item] = y;
        }
        return new Snapshot<T>(desired.Skip(insertionIndex).Take(inserted).ToArray(), previousY);
    }

    public void Animate<T>(Snapshot<T>? snapshot) where T : class
    {
        if (snapshot is null) return;
        // Keep the new first row visible even if the ScrollViewer anchors the old first row.
        FindScrollViewer(list)?.ChangeView(null, 0, null, true);
        list.UpdateLayout();
        var compositor = CompositionTarget.GetCompositorForCurrentThread();
        var easing = compositor.CreateCubicBezierEasingFunction(
            new Vector2(0.2f, 0f), new Vector2(0f, 1f));
        var batch = compositor.CreateScopedBatch(CompositionBatchTypes.Animation);

        foreach (var (item, previousY) in snapshot.PreviousY)
        {
            if (list.ContainerFromItem(item) is not ListViewItem container
                || container.ActualHeight <= 0) continue;
            var currentY = container.TransformToVisual(list).TransformPoint(new Point(0, 0)).Y;
            var displacement = previousY - currentY;
            if (Math.Abs(displacement) < 1 || currentY >= list.ActualHeight) continue;

            var move = compositor.CreateVector3KeyFrameAnimation();
            move.Target = "Translation";
            move.InsertKeyFrame(0f, new Vector3(0, (float)displacement, 0));
            move.InsertKeyFrame(1f, Vector3.Zero, easing);
            move.Duration = Duration;
            container.Translation = Vector3.Zero;
            container.StartAnimation(move);
            active[container] = [move];
        }

        foreach (var item in snapshot.NewItems)
        {
            if (list.ContainerFromItem(item) is not ListViewItem container
                || container.ActualHeight <= 0) continue;

            var fade = compositor.CreateScalarKeyFrameAnimation();
            fade.Target = "Opacity";
            fade.InsertKeyFrame(0f, 0.1f);
            fade.InsertKeyFrame(0.28f, 0.2f);
            fade.InsertKeyFrame(1f, 1f, easing);
            fade.Duration = Duration;

            var move = compositor.CreateVector3KeyFrameAnimation();
            move.Target = "Translation";
            move.InsertKeyFrame(0f, new Vector3(0, -12, 0));
            move.InsertKeyFrame(1f, Vector3.Zero, easing);
            move.Duration = Duration;

            container.Opacity = 1;
            container.Translation = Vector3.Zero;
            container.StartAnimation(fade);
            container.StartAnimation(move);
            active[container] = [fade, move];
        }

        var version = ++animationVersion;
        batch.Completed += (_, _) =>
        {
            if (version == animationVersion) Reset();
        };
        batch.End();
    }

    public void Reset()
    {
        animationVersion++;
        foreach (var (container, animations) in active)
        {
            foreach (var animation in animations) container.StopAnimation(animation);
            container.Opacity = 1;
            container.Translation = Vector3.Zero;
        }
        active.Clear();
    }

    private static ScrollViewer? FindScrollViewer(DependencyObject root)
    {
        if (root is ScrollViewer scroll) return scroll;
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
            if (FindScrollViewer(VisualTreeHelper.GetChild(root, index)) is { } child)
                return child;
        return null;
    }
}
