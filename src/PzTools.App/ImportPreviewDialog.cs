using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace PzTools.App;

public sealed class ImportPreviewDialog : ContentDialog
{
    protected override void OnApplyTemplate()
    {
        base.OnApplyTemplate();

        // 기본 버튼과 키보드/기본 동작은 유지하고 명령 영역의 배치만 조정합니다.
        if (GetTemplateChild("CommandSpace") is Grid commands)
        {
            commands.HorizontalAlignment = HorizontalAlignment.Right;
            commands.Width = 312;
            commands.Padding = new Thickness(24, 16, 24, 16);
        }
    }
}
