using Microsoft.UI.Xaml.Controls;

namespace PzTools.App;

internal static class ComboBoxLocalization
{
    // A closed ComboBox caches the string extracted from its selected ComboBoxItem.
    // Relabeling Content alone does not rebuild that selection-box presentation.
    // Callers suppress their selection-change side effects during this refresh.
    public static void UpdateLabels(ComboBox combo, Action update)
    {
        var selected = combo.SelectedItem;
        try
        {
            combo.SelectedItem = null;
            update();
        }
        finally
        {
            // Preserve the same item/Tag, visibility and selection, including no selection.
            // Re-selecting after the labels change refreshes the closed display as well.
            combo.SelectedItem = selected;
        }
    }
}
