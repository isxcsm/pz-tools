using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace PzTools.App;

public sealed class ImportPreviewDialog : ContentDialog
{
    protected override void OnApplyTemplate()
    {
        base.OnApplyTemplate();

        // The default button and keyboard behaviour stay; only the command area's layout changes.
        if (GetTemplateChild("CommandSpace") is Grid commands)
        {
            commands.HorizontalAlignment = HorizontalAlignment.Right;
            commands.Width = 312;
            commands.Padding = new Thickness(24, 16, 24, 16);
        }
    }
}
