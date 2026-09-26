using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;

namespace PzTools.App;

public sealed partial class MainWindowShell
{
    // Set this to the creator's https://buymeacoffee.com/<account> page when ready.
    // A null destination is a visible, disabled placeholder: no browser or payment request.
    private static readonly Uri? SupportPage = null;

    private void LocalizeSupportButton()
    {
        CoffeeSupportTitle.Text = Localizer.Get("CoffeeSupport.Title");
        CoffeeSupportMessage.Text = Localizer.Get("CoffeeSupport.Message");
        CoffeeSupportButton.NavigateUri = SupportPage;
        CoffeeSupportButton.IsEnabled = SupportPage is not null;
        var label = $"{CoffeeSupportMessage.Text} {CoffeeSupportTitle.Text}";
        var hint = SupportPage is null ? Localizer.Get("CoffeeSupport.NotReady") : label;
        AppToolTip.SetTip(CoffeeSupportArea, hint);
        AutomationProperties.SetName(CoffeeSupportButton, label);
        AutomationProperties.SetHelpText(CoffeeSupportButton, hint);
    }
}
