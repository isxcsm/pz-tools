using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace PzTools.App;

/// <summary>
/// A card in the pane's attention group (docs/ui-ux-contract.md, "Cards that need attention"): a title, an optional
/// line, an optional action and a ✕. Its owner sets the words and decides when it shows; the card raises
/// <see cref="Action"/> and <see cref="Closed"/>. Every such card shares this one shape, so a new one needs no layout.
/// </summary>
public sealed partial class AttentionCard : UserControl
{
    private bool pointer;

    public AttentionCard()
    {
        InitializeComponent();
        // The ✕ shows while the pointer is on the card or the keyboard is in it, and is unseen otherwise: still there
        // for Tab, which brings it into view.
        PointerEntered += (_, _) => { pointer = true; RevealClose(); };
        PointerExited += (_, _) => { pointer = false; RevealClose(); };
        PointerCanceled += (_, _) => { pointer = false; RevealClose(); };
        GotFocus += (_, _) => RevealClose();
        LostFocus += (_, _) => RevealClose();
        // Scripts and screen readers find the buttons by the card's name.
        Loaded += (_, _) =>
        {
            AutomationProperties.SetAutomationId(CloseButton, Name + "Close");
            AutomationProperties.SetAutomationId(ActionButton, Name + "Action");
        };
        Localize();
    }

    /// <summary>The ✕ was pressed; the card has hidden itself.</summary>
    public event EventHandler? Closed;

    /// <summary>The action strip was pressed.</summary>
    public event EventHandler? Action;

    public string Title
    {
        get => TitleText.Text;
        set => TitleText.Text = value;
    }

    /// <summary>The line under the title; none when empty.</summary>
    public string Message
    {
        get => MessageText.Text;
        set
        {
            MessageText.Text = value;
            MessageText.Visibility = string.IsNullOrEmpty(value) ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    /// <summary>The words of the action strip; no strip when empty.</summary>
    public string ActionLabel
    {
        get => ActionText.Text;
        set
        {
            ActionText.Text = value;
            ActionButton.Visibility = string.IsNullOrEmpty(value) ? Visibility.Collapsed : Visibility.Visible;
            AutomationProperties.SetName(ActionButton, value);
        }
    }

    /// <summary>Names the ✕ in the current language.</summary>
    public void Localize()
    {
        AutomationProperties.SetName(CloseButton, Localizer.Get("Close"));
        AppToolTip.SetTip(CloseButton, Localizer.Get("Close"));
    }

    private void RevealClose() => CloseButton.Opacity = pointer || CloseButton.FocusState != FocusState.Unfocused
        || (XamlRoot is not null && Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(XamlRoot) is DependencyObject focused
            && IsInside(focused))
        ? 1 : 0;

    private bool IsInside(DependencyObject element)
    {
        for (var current = element; current is not null; current = VisualTreeHelper.GetParent(current))
            if (ReferenceEquals(current, this)) return true;
        return false;
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e)
    {
        Visibility = Visibility.Collapsed;
        Closed?.Invoke(this, EventArgs.Empty);
    }

    private void ActionButton_Click(object sender, RoutedEventArgs e) => Action?.Invoke(this, EventArgs.Empty);
}
