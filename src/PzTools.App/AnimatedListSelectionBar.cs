using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace PzTools.App;

/// <summary>NavigationView와 같은 컴포지션 늘림/수축으로 목록 선택 표시를 이동합니다.</summary>
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
            list.DispatcherQueue.TryEnqueue(Update);
        };
        list.Loaded += (_, _) =>
        {
            if (!scrollHooked) scrollHooked = HookScrollViewer(list);
            Update();
        };
        list.LayoutUpdated += (_, _) => Update();
        surface.SizeChanged += (_, _) => Update();
    }

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

        // 새 막대의 레이아웃 위치를 확정한 뒤 그 위치에 대한 상대 이동량을 애니메이션합니다.
        surface.UpdateLayout();
        var compositor = CompositionTarget.GetCompositorForCurrentThread();
        var batch = compositor.CreateScopedBatch(CompositionBatchTypes.Animation);
        StartIndicatorAnimation(bar, previousTop, previousHeight, top, height);
        var version = animationVersion;
        batch.Completed += (_, _) =>
        {
            if (version == animationVersion) ResetAnimation();
        };
        batch.End();
    }

    private void StartIndicatorAnimation(
        Border indicator, double from, double fromHeight, double to, double toHeight)
    {
        var compositor = CompositionTarget.GetCompositorForCurrentThread();
        var movingDown = from < to;
        var fromTranslation = (float)(from - to);
        var stretchEase = compositor.CreateCubicBezierEasingFunction(
            new Vector2(0.9f, 0.1f), new Vector2(1f, 0.2f));
        var settleEase = compositor.CreateCubicBezierEasingFunction(
            new Vector2(0.1f, 0.9f), new Vector2(0.2f, 1f));

        // 한 막대의 앞쪽 끝이 먼저 도착하고 뒤쪽 끝이 따라오게 합니다.
        // 두 막대를 따로 그리면 이동 중 선택 항목이 두 개인 것처럼 보입니다.
        var stretchedHeight = movingDown
            ? to + toHeight - from
            : from + fromHeight - to;
        // Canvas.Top은 이미 새 선택 항목의 좌표입니다. XAML 레이아웃이 소유하는
        // Visual.Offset에 절대 좌표를 다시 넣으면 위치가 중복 적용되므로 상대 이동만 애니메이션합니다.
        var translation = compositor.CreateVector3KeyFrameAnimation();
        translation.Target = "Translation";
        translation.InsertKeyFrame(0, new Vector3(0, fromTranslation, 0));
        translation.InsertKeyFrame(StretchKeyFrame,
            new Vector3(0, movingDown ? fromTranslation : 0, 0), stretchEase);
        translation.InsertKeyFrame(1, Vector3.Zero, settleEase);
        translation.Duration = AnimationDuration;

        var scale = compositor.CreateVector3KeyFrameAnimation();
        scale.Target = "Scale";
        scale.InsertKeyFrame(0, new Vector3(1, (float)(fromHeight / toHeight), 1));
        scale.InsertKeyFrame(StretchKeyFrame,
            new Vector3(1, (float)(stretchedHeight / toHeight), 1), stretchEase);
        scale.InsertKeyFrame(1, Vector3.One, settleEase);
        scale.Duration = AnimationDuration;

        indicator.StartAnimation(translation);
        translationAnimation = translation;
        indicator.StartAnimation(scale);
        scaleAnimation = scale;
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
