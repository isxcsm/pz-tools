using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace PzTools.App;

/// <summary>A standard ContentDialog that also closes when its modal backdrop is tapped.</summary>
internal sealed class LightDismissContentDialog : ContentDialog
{
    private UIElement? smokeLayer;

    protected override void OnApplyTemplate()
    {
        if (smokeLayer is not null) smokeLayer.Tapped -= SmokeLayer_Tapped;
        base.OnApplyTemplate();

        // WinUI moves this named template part into its own backdrop popup. Keep
        // the default template and modal behavior; do not discover or modify popups.
        smokeLayer = GetTemplateChild("SmokeLayerBackground") as UIElement;
        if (smokeLayer is not null) smokeLayer.Tapped += SmokeLayer_Tapped;
    }

    private void SmokeLayer_Tapped(object sender, TappedRoutedEventArgs args)
    {
        args.Handled = true;
        // Hide follows ContentDialog's Closing/deferral path, so a pending settings
        // write can cancel dismissal without losing focus containment or the backdrop.
        Hide();
    }
}
