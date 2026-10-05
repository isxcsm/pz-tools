using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace PzTools.App;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        // Clicks and keys close tooltips through the shell (MainWindowShell), which the window may replace.
        Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated) AppToolTip.CloseCurrent();
        };
        Closed += (_, _) => AppToolTip.CloseCurrent();
        Title = Localizer.Get("AppTitle");
        // The custom title bar, the taskbar, Alt+Tab and the executable use the same source icon.
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Navigation", "pztools.ico"));
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
        AppWindow.TitleBar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
    }
}
