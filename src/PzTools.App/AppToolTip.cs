using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Input;

namespace PzTools.App;

public static class AppToolTip
{
    private static readonly ConditionalWeakTable<FrameworkElement, Presenter> Presenters = new();
    private static Presenter? current;

    public static readonly DependencyProperty TipProperty = DependencyProperty.RegisterAttached(
        "Tip", typeof(string), typeof(AppToolTip), new PropertyMetadata(null, OnTipChanged));

    public static string? GetTip(DependencyObject owner) => (string?)owner.GetValue(TipProperty);

    public static void SetTip(DependencyObject owner, string? text)
    {
        if (StringComparer.Ordinal.Equals(GetTip(owner), text)) return;
        owner.SetValue(TipProperty, text);
    }

    private static void OnTipChanged(DependencyObject owner, DependencyPropertyChangedEventArgs args)
    {
        if (owner is FrameworkElement element)
            Presenters.GetValue(element, static element => new Presenter(element)).UpdateText((string?)args.NewValue);
    }

    // The one waiting out its rest before showing, so closing everything also stops a tip about to appear.
    private static Presenter? pending;

    public static void CloseCurrent()
    {
        current?.Dismiss();
        pending?.Dismiss();
    }

    /// <summary>
    /// Whether the pointer is still over the element. Pointer enter and exit bubble from its children, so moving between
    /// a legend's dot, name and figure reports leaving the legend itself; only a pointer outside its bounds has left.
    /// </summary>
    public static bool StillOver(FrameworkElement element, PointerRoutedEventArgs args)
    {
        var point = args.GetCurrentPoint(element).Position;
        return point.X >= 0 && point.Y >= 0 && point.X < element.ActualWidth && point.Y < element.ActualHeight;
    }

    // As Windows' own tips: a moment's rest before the first, then the next at once while one was just showing, so a
    // pointer passing over a row of them does not flash each one.
    private static readonly TimeSpan InitialDelay = TimeSpan.FromMilliseconds(350);
    private static readonly TimeSpan BetweenDelay = TimeSpan.FromMilliseconds(500);
    private static long lastClosed;

    private sealed class Presenter
    {
        // A pointer that leaves and comes back within this keeps the tip open: an element a line of text high is left
        // and entered again by the smallest move up or down, and each close and open replayed the tip's appearance.
        private static readonly TimeSpan CloseGrace = TimeSpan.FromMilliseconds(200);
        private readonly FrameworkElement owner;
        private readonly ToolTip tooltip = new() { IsHitTestVisible = false };
        private bool hovered;
        // Pressed: closed, as Windows' own tips close on a click, and not shown again until the pointer has left.
        private bool pressed;
        private string? text;
        private Microsoft.UI.Dispatching.DispatcherQueueTimer? opening, closing;

        public Presenter(FrameworkElement owner)
        {
            this.owner = owner;
            owner.PointerEntered += OnEntered;
            owner.PointerExited += OnExited;
            owner.PointerCanceled += (_, _) => Dismiss();
            // A button handles its own press, so the press is heard even when handled. What it opens (a flyout, a menu)
            // is not covered by its tip.
            owner.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) =>
            {
                pressed = true;
                opening?.Stop();
                Hide();
            }), true);
            owner.Unloaded += (_, _) => Dismiss();
            owner.GotFocus += (_, _) =>
            {
                if (owner is Microsoft.UI.Xaml.Controls.Control { FocusState: FocusState.Keyboard }) Show(keyboard: true);
            };
            owner.LostFocus += (_, _) => { if (!hovered) Hide(); };
        }

        public void UpdateText(string? value)
        {
            text = value;
            if (string.IsNullOrEmpty(text))
            {
                Hide();
                ToolTipService.SetToolTip(owner, null);
                tooltip.Content = null;
            }
            else
            {
                // The same words again change nothing on screen; new ones replace them in place.
                if (!Equals(tooltip.Content, text)) tooltip.Content = text;
                // WinUI also requires the service's owner/container registration
                // when IsOpen is set manually; PlacementTarget alone is insufficient.
                if (!ReferenceEquals(ToolTipService.GetToolTip(owner), tooltip))
                    ToolTipService.SetToolTip(owner, tooltip);
                if (hovered) Show();
            }
        }

        private Microsoft.UI.Dispatching.DispatcherQueueTimer Timer(TimeSpan interval, Action tick)
        {
            var timer = owner.DispatcherQueue.CreateTimer();
            timer.Interval = interval;
            timer.IsRepeating = false;
            timer.Tick += (_, _) => tick();
            return timer;
        }

        private void OnEntered(object sender, PointerRoutedEventArgs args)
        {
            if (args.Pointer.PointerDeviceType == PointerDeviceType.Touch) return;
            closing?.Stop();
            // Already over it, coming from one of its children: the tip showing stays as it is.
            if (hovered) return;
            hovered = true;
            pressed = false;
            // Back within the grace: still open, nothing to show again.
            if (tooltip.IsOpen) { current = this; return; }
            if (System.Diagnostics.Stopwatch.GetElapsedTime(lastClosed) < BetweenDelay || current is not null) { Show(); return; }
            pending = this;
            (opening ??= Timer(InitialDelay, () =>
            {
                if (pending == this) pending = null;
                if (hovered) Show();
            })).Start();
        }

        private void OnExited(object sender, PointerRoutedEventArgs args)
        {
            // Onto one of its own children: still over it.
            if (StillOver(owner, args)) return;
            hovered = false;
            pressed = false;
            StopOpening();
            if (current != this) return;
            (closing ??= Timer(CloseGrace, Closed)).Start();
        }

        // Left for good: closed, and an element it sits in that is still pointed at shows its own again.
        private void Closed()
        {
            if (hovered) return;
            Hide();
            for (var parent = VisualTreeHelper.GetParent(owner); parent is not null; parent = VisualTreeHelper.GetParent(parent))
                if (parent is FrameworkElement element && Presenters.TryGetValue(element, out var presenter)
                    && presenter.hovered && !string.IsNullOrEmpty(presenter.text))
                {
                    presenter.Show();
                    break;
                }
        }

        // The gap Windows' own tips keep from what they are for: opened by the service, a tip stands this far off its
        // element (WinUI's DEFAULT_MOUSE_OFFSET and DEFAULT_KEYBOARD_OFFSET); opened by hand it gets none and sat on
        // the element's edge, against the pointer.
        private const double PointerGap = 20, KeyboardGap = 12;

        private void Show(bool keyboard = false)
        {
            if (pressed || string.IsNullOrEmpty(text) || !owner.IsLoaded || owner.XamlRoot is null || UnderOpenPopup()) return;
            // Nested tooltip owners prefer the innermost hovered element.
            if (current is not null && current != this)
                for (var parent = VisualTreeHelper.GetParent(current.owner); parent is not null; parent = VisualTreeHelper.GetParent(parent))
                    if (ReferenceEquals(parent, owner)) return;
            if (current != this) current?.Hide();
            current = this;
            if (tooltip.IsOpen) return;
            try
            {
                tooltip.XamlRoot = owner.XamlRoot;
                tooltip.PlacementTarget = owner;
                tooltip.VerticalOffset = keyboard ? KeyboardGap : PointerGap;
                tooltip.IsOpen = true;
            }
            // An element leaving the tree as its tip opens: no tip, rather than the app.
            catch (Exception exception) when (exception is System.Runtime.InteropServices.COMException or ArgumentException)
            {
                current = null;
            }
        }

        // A flyout or menu open over the page, the element not in it: a tip there would cover what was just opened.
        private bool UnderOpenPopup()
        {
            foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(owner.XamlRoot))
            {
                if (popup.Child is null or ToolTip) continue;
                var inside = false;
                for (DependencyObject? parent = owner; parent is not null; parent = VisualTreeHelper.GetParent(parent))
                    if (ReferenceEquals(parent, popup.Child) || ReferenceEquals(parent, popup)) { inside = true; break; }
                if (!inside) return true;
            }
            return false;
        }

        private void StopOpening()
        {
            opening?.Stop();
            if (pending == this) pending = null;
        }

        private void Hide()
        {
            closing?.Stop();
            if (tooltip.IsOpen) lastClosed = System.Diagnostics.Stopwatch.GetTimestamp();
            try { tooltip.IsOpen = false; }
            catch (Exception exception) when (exception is System.Runtime.InteropServices.COMException or ArgumentException) { }
            if (current == this) current = null;
        }

        public void Dismiss()
        {
            hovered = false;
            StopOpening();
            Hide();
        }
    }
}
