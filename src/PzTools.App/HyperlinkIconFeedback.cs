using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace PzTools.App;

/// <summary>Decorates a native hyperlink's icon without replacing its input or focus behavior.</summary>
internal sealed class HyperlinkIconFeedback : IDisposable
{
    private readonly HyperlinkButton button;
    private readonly Microsoft.UI.Xaml.Shapes.Path icon;
    private readonly FrameworkElement host;
    private readonly ContentPresenter presenter;
    private readonly UISettings uiSettings;
    private readonly AccessibilitySettings accessibility = new();
    private readonly SolidColorBrush brush = new();
    private readonly object originalFill;
    private readonly double originalWidth;
    private readonly double originalHeight;
    private readonly double originalLeft;
    private readonly double originalTop;
    private readonly List<Action> cleanup = [];
    private Storyboard? transition;
    private (Color Color, double Width, double Height, double Left, double Top)? destination;
    private bool updatePending;
    private bool settlePending;
    private bool disposed;

    public static HyperlinkIconFeedback? Attach(HyperlinkButton button, Microsoft.UI.Xaml.Shapes.Path icon,
        FrameworkElement host, UISettings uiSettings)
    {
        HyperlinkIconFeedback? feedback = null;
        try
        {
            button.ApplyTemplate();
            // Observe public button properties, never materialize the template's
            // deferred VisualStateGroups. An unknown template keeps its native icon.
            if (VisualTreeHelper.GetChildrenCount(button) == 0
                || VisualTreeHelper.GetChild(button, 0) is not ContentPresenter presenter
                || presenter.Foreground is not SolidColorBrush)
                return null;
            feedback = new(button, icon, host, presenter, uiSettings);
            feedback.Initialize();
            return feedback;
        }
        catch (Exception exception) when (IsFeedbackFailure(exception))
        {
            feedback?.Dispose();
            ReportFailure(exception);
            return null;
        }
    }

    private HyperlinkIconFeedback(HyperlinkButton button, Microsoft.UI.Xaml.Shapes.Path icon, FrameworkElement host,
        ContentPresenter presenter, UISettings uiSettings)
    {
        this.button = button;
        this.icon = icon;
        this.host = host;
        this.presenter = presenter;
        this.uiSettings = uiSettings;
        originalFill = icon.ReadLocalValue(Shape.FillProperty);
        originalWidth = icon.Width;
        originalHeight = icon.Height;
        originalLeft = Canvas.GetLeft(icon);
        originalTop = Canvas.GetTop(icon);
    }

    private void Initialize()
    {
        // The instance already exists when setup starts, so even partial setup
        // can be rolled back. Restore each property independently during cleanup.
        cleanup.Add(() =>
        {
            if (originalFill == DependencyProperty.UnsetValue) icon.ClearValue(Shape.FillProperty);
            else icon.SetValue(Shape.FillProperty, originalFill);
        });
        cleanup.Add(() => icon.Width = originalWidth);
        cleanup.Add(() => icon.Height = originalHeight);
        cleanup.Add(() => Canvas.SetLeft(icon, originalLeft));
        cleanup.Add(() => Canvas.SetTop(icon, originalTop));
        // Never animate or mutate a shared theme brush.
        icon.Fill = brush;
        Observe(presenter, ContentPresenter.ForegroundProperty);
        Observe(button, ButtonBase.IsPointerOverProperty);
        Observe(button, ButtonBase.IsPressedProperty);
        Observe(button, ButtonBase.IsEnabledProperty);
        button.ActualThemeChanged += ThemeChanged;
        cleanup.Add(() => button.ActualThemeChanged -= ThemeChanged);
        // No CoreWindow-dependent settings events in this desktop app. Read the
        // current accessibility preferences on every native state/theme update.
        Update(animate: false);
    }

    private void Observe(DependencyObject owner, DependencyProperty property)
    {
        var token = owner.RegisterPropertyChangedCallback(property, (_, _) => RequestUpdate());
        cleanup.Add(() => owner.UnregisterPropertyChangedCallback(property, token));
    }

    private void ThemeChanged(FrameworkElement sender, object args) => RequestUpdate(animate: false);

    private void RequestUpdate(bool animate = true)
    {
        if (disposed) return;
        settlePending |= !animate;
        if (updatePending) return;
        updatePending = true;
        // Native state and foreground notifications can arrive separately in the
        // same turn. Sample them together once; never enqueue obsolete animations.
        try
        {
            if (!button.DispatcherQueue.TryEnqueue(() =>
            {
                updatePending = false;
                var useAnimation = !settlePending;
                settlePending = false;
                if (disposed) return;
                try { Update(useAnimation); }
                catch (Exception exception) when (IsFeedbackFailure(exception)) { DisableFeedback(exception); }
            }))
            {
                updatePending = false;
                settlePending = false;
            }
        }
        catch (Exception exception) when (IsFeedbackFailure(exception))
        {
            DisableFeedback(exception);
        }
    }

    private void Update(bool animate = true)
    {
        if (disposed || presenter.Foreground is not SolidColorBrush nativeBrush) return;
        var color = nativeBrush.Color;
        color.A = (byte)Math.Round(color.A * nativeBrush.Opacity);
        var motion = uiSettings.AnimationsEnabled && !accessibility.HighContrast;
        var state = !button.IsEnabled ? "Disabled" : button.IsPressed ? "Pressed"
            : button.IsPointerOver ? "PointerOver" : "Normal";
        var scale = motion ? state switch { "PointerOver" => 1.04, "Pressed" => 0.98, _ => 1d } : 1d;
        var y = motion && state == "PointerOver" ? -1d : 0d;
        // Resize the actual vector, not a cached surface. The fixed Canvas keeps
        // the label/layout still. Snap settled bounds to the physical pixel grid.
        var rasterScale = icon.XamlRoot?.RasterizationScale ?? 1d;
        double Snap(double value) => Math.Round(value * rasterScale) / rasterScale;
        var width = Snap(originalWidth * scale);
        var height = Snap(originalHeight * scale);
        var left = Snap((host.Width - width) / 2);
        var top = Snap((host.Height - height) / 2 + y);
        var target = (color, width, height, left, top);
        if (animate && destination == target) return;
        destination = target;

        // Retarget from the visible values, not the old animation's end point.
        // One replaceable storyboard: rapid hover/press/exit never queues work.
        var previousColor = brush.Color;
        var previousWidth = icon.Width;
        var previousHeight = icon.Height;
        var previousLeft = Canvas.GetLeft(icon);
        var previousTop = Canvas.GetTop(icon);
        transition?.Stop();
        transition = null;
        brush.Color = color;
        icon.Width = width;
        icon.Height = height;
        Canvas.SetLeft(icon, left);
        Canvas.SetTop(icon, top);
        if (!animate || !motion || state == "Disabled") return;

        var duration = new Duration(TimeSpan.FromMilliseconds(state == "Pressed" ? 100 : 180));
        var easing = new CubicEase { EasingMode = EasingMode.EaseOut };
        transition = new Storyboard { FillBehavior = FillBehavior.Stop };
        var tint = new ColorAnimation
        {
            From = previousColor, To = color, Duration = duration,
            EasingFunction = easing, EnableDependentAnimation = true
        };
        Storyboard.SetTarget(tint, brush);
        Storyboard.SetTargetProperty(tint, nameof(SolidColorBrush.Color));
        transition.Children.Add(tint);
        AddMotion(nameof(FrameworkElement.Width), previousWidth, width);
        AddMotion(nameof(FrameworkElement.Height), previousHeight, height);
        AddMotion("(Canvas.Left)", previousLeft, left);
        AddMotion("(Canvas.Top)", previousTop, top);
        transition.Begin();

        void AddMotion(string property, double from, double to)
        {
            // Width/Height invalidate vector layout/tessellation each frame;
            // opt into dependent animation only for this small, fixed-slot icon.
            var animation = new DoubleAnimation
            {
                From = from, To = to, Duration = duration, EasingFunction = easing,
                EnableDependentAnimation = true
            };
            Storyboard.SetTarget(animation, icon);
            Storyboard.SetTargetProperty(animation, property);
            transition.Children.Add(animation);
        }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        updatePending = settlePending = false;
        TryCleanup(() => transition?.Stop());
        transition = null;
        for (var index = cleanup.Count - 1; index >= 0; index--) TryCleanup(cleanup[index]);
        cleanup.Clear();
    }

    private void DisableFeedback(Exception exception)
    {
        ReportFailure(exception);
        Dispose();
    }

    private static void TryCleanup(Action action)
    {
        try { action(); }
        catch (Exception exception) when (IsFeedbackFailure(exception)) { ReportFailure(exception); }
    }

    // This boundary is exclusively cosmetic: leave native link behavior intact
    // on managed/WinRT presentation errors, but never swallow resource exhaustion.
    private static bool IsFeedbackFailure(Exception exception) => exception is not OutOfMemoryException;
    private static void ReportFailure(Exception exception) =>
        System.Diagnostics.Trace.TraceError("Hyperlink icon feedback disabled: {0}", exception);
}
