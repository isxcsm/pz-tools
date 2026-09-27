using PzTools.Process.Contracts;
using System.Globalization;
using Microsoft.Windows.ApplicationModel.Resources;

namespace PzTools.App;

internal static class Localizer
{
    private static readonly ResourceManager Manager = new();
    private static readonly ResourceMap Resources =
        Manager.MainResourceMap.GetSubtree("Resources");
    private static ResourceContext context = Manager.CreateResourceContext();

    public static CultureInfo Culture { get; private set; } =
        CultureInfo.GetCultureInfo("ko-KR");

    public static string Get(string key) =>
        Resources.GetValue(key.Replace('.', '/'), context).ValueAsString;

    public static string Format(string key, params object?[] arguments) =>
        string.Format(Culture, Get(key), arguments);

    public static void SetLanguage(SupportedLanguage language)
    {
        var tag = LanguageCatalog.Get(language).Tag;
        var culture = CultureInfo.GetCultureInfo(tag);
        var next = Manager.CreateResourceContext();
        next.QualifierValues["Language"] = tag == "en-US" ? tag : tag + ";en-US";
        context = next;
        Culture = culture;
        CultureInfo.CurrentCulture = culture;
        CultureInfo.CurrentUICulture = culture;
        CultureInfo.DefaultThreadCurrentCulture = culture;
        CultureInfo.DefaultThreadCurrentUICulture = culture;
    }
}
