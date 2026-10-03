using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace PzTools.App;

/// <summary>
/// Its children in a row, left to right, going on to the next line where the row is full: a legend that keeps every
/// item whole in a narrow window rather than cutting the last ones off.
/// </summary>
public sealed partial class WrapPanel : Panel
{
    public double HorizontalSpacing { get; set; }
    public double VerticalSpacing { get; set; }

    protected override Size MeasureOverride(Size availableSize)
    {
        double width = 0, x = 0, y = 0, line = 0;
        foreach (var child in Children)
        {
            child.Measure(new Size(availableSize.Width, double.PositiveInfinity));
            var size = child.DesiredSize;
            if (size.Width == 0 && size.Height == 0) continue;
            if (x > 0 && x + size.Width > availableSize.Width) { y += line + VerticalSpacing; x = 0; line = 0; }
            x += size.Width + HorizontalSpacing;
            line = Math.Max(line, size.Height);
            width = Math.Max(width, x - HorizontalSpacing);
        }
        return new Size(double.IsInfinity(availableSize.Width) ? width : Math.Min(width, availableSize.Width), y + line);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double x = 0, y = 0, line = 0;
        foreach (var child in Children)
        {
            var size = child.DesiredSize;
            if (size.Width == 0 && size.Height == 0) { child.Arrange(new Rect(0, 0, 0, 0)); continue; }
            if (x > 0 && x + size.Width > finalSize.Width) { y += line + VerticalSpacing; x = 0; line = 0; }
            child.Arrange(new Rect(x, y, size.Width, size.Height));
            x += size.Width + HorizontalSpacing;
            line = Math.Max(line, size.Height);
        }
        return finalSize;
    }
}
