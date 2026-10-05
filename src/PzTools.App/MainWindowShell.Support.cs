using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;

namespace PzTools.App;

public sealed partial class MainWindowShell
{
    private static readonly Uri SupportPage = new("https://buymeacoffee.com/iou3019");
    private HyperlinkIconFeedback? coffeeSupportFeedback;

    private void CoffeeSupportButton_Loaded(object sender, RoutedEventArgs e) =>
        coffeeSupportFeedback ??= HyperlinkIconFeedback.Attach(
            CoffeeSupportButton, CoffeeSupportIcon, CoffeeSupportIconHost, navigationUiSettings);

    private void CoffeeSupportButton_Unloaded(object sender, RoutedEventArgs e)
    {
        coffeeSupportFeedback?.Dispose();
        coffeeSupportFeedback = null;
    }

    // Opened as the player's, not by the link's own navigation, which would start the browser with this app's rights.
    private void CoffeeSupportButton_Click(object sender, RoutedEventArgs e)
    {
        try { ShellLaunch.Open(SupportPage.AbsoluteUri); }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            ShowActionError(Localizer.Get("CoffeeSupport.Title"), exception);
        }
    }

    private void LocalizeSupportButton()
    {
        CoffeeSupportTitle.Text = Localizer.Get("CoffeeSupport.Title");
        CoffeeSupportMessage.Text = Localizer.Get("CoffeeSupport.Message");
        CoffeeSupportButton.IsEnabled = true;
        var label = $"{CoffeeSupportMessage.Text} {CoffeeSupportTitle.Text}";
        AutomationProperties.SetName(CoffeeSupportButton, label);
        AutomationProperties.SetHelpText(CoffeeSupportButton, label);
    }
}
