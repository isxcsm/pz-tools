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

    public static void CloseCurrent() => current?.Dismiss();

    private sealed class Presenter
    {
        private readonly FrameworkElement owner;
        private readonly ToolTip tooltip = new() { IsHitTestVisible = false };
        private bool hovered;
        private string? text;

        public Presenter(FrameworkElement owner)
        {
            this.owner = owner;
            owner.PointerEntered += OnEntered;
            owner.PointerExited += OnExited;
            owner.PointerCanceled += (_, _) => Dismiss();
            owner.Unloaded += (_, _) => Dismiss();
            owner.GotFocus += (_, _) =>
            {
                if (owner is Microsoft.UI.Xaml.Controls.Control { FocusState: FocusState.Keyboard }) Show();
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
                tooltip.Content = text;
                // WinUI also requires the service's owner/container registration
                // when IsOpen is set manually; PlacementTarget alone is insufficient.
                if (!ReferenceEquals(ToolTipService.GetToolTip(owner), tooltip))
                    ToolTipService.SetToolTip(owner, tooltip);
                if (hovered) Show();
            }
        }

        private void OnEntered(object sender, PointerRoutedEventArgs args)
        {
            if (args.Pointer.PointerDeviceType == PointerDeviceType.Touch) return;
            hovered = true;
            Show();
        }

        private void OnExited(object sender, PointerRoutedEventArgs args)
        {
            hovered = false;
            if (current != this) return;
            Hide();
            for (var parent = VisualTreeHelper.GetParent(owner); parent is not null; parent = VisualTreeHelper.GetParent(parent))
                if (parent is FrameworkElement element && Presenters.TryGetValue(element, out var presenter)
                    && presenter.hovered && !string.IsNullOrEmpty(presenter.text))
                {
                    presenter.Show();
                    break;
                }
        }

        private void Show()
        {
            if (string.IsNullOrEmpty(text) || !owner.IsLoaded || owner.XamlRoot is null) return;
            // Nested tooltip owners prefer the innermost hovered element.
            if (current is not null && current != this)
                for (var parent = VisualTreeHelper.GetParent(current.owner); parent is not null; parent = VisualTreeHelper.GetParent(parent))
                    if (ReferenceEquals(parent, owner)) return;
            if (current != this) current?.Hide();
            current = this;
            if (tooltip.IsOpen) return;
            tooltip.XamlRoot = owner.XamlRoot;
            tooltip.PlacementTarget = owner;
            tooltip.IsOpen = true;
        }

        private void Hide()
        {
            tooltip.IsOpen = false;
            if (current == this) current = null;
        }

        public void Dismiss()
        {
            hovered = false;
            Hide();
        }
    }
}
