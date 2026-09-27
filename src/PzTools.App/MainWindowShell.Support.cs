using Microsoft.UI.Xaml.Automation;

namespace PzTools.App;

public sealed partial class MainWindowShell
{
    private static readonly Uri SupportPage = new("https://buymeacoffee.com/iou3019");

    private void LocalizeSupportButton()
    {
        CoffeeSupportTitle.Text = Localizer.Get("CoffeeSupport.Title");
        CoffeeSupportMessage.Text = Localizer.Get("CoffeeSupport.Message");
        CoffeeSupportButton.NavigateUri = SupportPage;
        CoffeeSupportButton.IsEnabled = true;
        var label = $"{CoffeeSupportMessage.Text} {CoffeeSupportTitle.Text}";
        AppToolTip.SetTip(CoffeeSupportArea, label);
        AutomationProperties.SetName(CoffeeSupportButton, label);
        AutomationProperties.SetHelpText(CoffeeSupportButton, label);
    }
}
