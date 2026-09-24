using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace PzTools.App;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Content.AddHandler(UIElement.PointerPressedEvent,
            new PointerEventHandler((_, _) => AppToolTip.CloseCurrent()), true);
        Content.AddHandler(UIElement.KeyDownEvent,
            new KeyEventHandler((_, _) => AppToolTip.CloseCurrent()), true);
        Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated) AppToolTip.CloseCurrent();
        };
        Closed += (_, _) => AppToolTip.CloseCurrent();
        Title = Localizer.Get("AppTitle");
        // 사용자 정의 타이틀바와 작업 표시줄/Alt+Tab/실행 파일에 같은 원본 아이콘을 사용합니다.
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Navigation", "pztools.ico"));
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
        AppWindow.TitleBar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
    }
}
