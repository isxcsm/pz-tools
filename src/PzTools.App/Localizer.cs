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

    // Every resource text of every language, pointing back to its key. About a second of work for 18
    // languages, so it is started in the background at launch (Warm), and a failed entry never spoils the rest.
    private static readonly Lazy<Dictionary<string, string>> KeysByText = new(() =>
    {
        var keys = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var language in LanguageCatalog.All)
        {
            ResourceContext languageContext;
            try
            {
                languageContext = Manager.CreateResourceContext();
                languageContext.QualifierValues["Language"] = language.Tag;
            }
            catch (Exception) { continue; }
            for (uint index = 0; index < Resources.ResourceCount; index++)
            {
                try
                {
                    var (name, candidate) = Resources.GetValueByIndex(index, languageContext);
                    var text = candidate?.ValueAsString;
                    if (text is { Length: > 1 }) keys.TryAdd(text, name.Replace('/', '.'));
                }
                catch (Exception) { }
            }
        }
        return keys;
    });

    /// <summary>Builds the table <see cref="Translate"/> reads, off the UI thread, so the first log shown does not wait.</summary>
    public static void Warm() => ThreadPool.QueueUserWorkItem(_ => { try { _ = KeysByText.Value; } catch (Exception) { } });

    /// <summary>
    /// Text that was shown, and kept, in whatever language the app used then (a log entry of a notice,
    /// for one), in today's language. Text that is not a whole resource of any language is returned as is.
    /// </summary>
    public static string Translate(string text)
    {
        if (string.IsNullOrEmpty(text)) return text;
        try { return KeysByText.Value.TryGetValue(text, out var key) ? Get(key) : text; }
        catch (Exception) { return text; }
    }

    public static void SetLanguage(SupportedLanguage language)
    {
        var tag = LanguageCatalog.Get(language).Tag;
        var culture = CultureInfo.GetCultureInfo(tag);
        var next = Manager.CreateResourceContext();
        next.QualifierValues["Language"] = tag == "en-US" ? tag : tag + ";en-US";
        context = next;
        Culture = culture;
        // ApplicationLanguages.PrimaryLanguageOverride is deliberately not set. It would put WinUI's own text
        // in the app's language, but it also makes every resource context answer in that one language
        // whatever language it asks for, and Translate below needs to read all of them.
        CultureInfo.CurrentCulture = culture;
        CultureInfo.CurrentUICulture = culture;
        CultureInfo.DefaultThreadCurrentCulture = culture;
        CultureInfo.DefaultThreadCurrentUICulture = culture;
    }
}
