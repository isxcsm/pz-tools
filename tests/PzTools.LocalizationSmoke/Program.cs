using System.Globalization;
using System.Text;
using System.Xml.Linq;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using PzTools.App;
using PzTools.Process.Contracts;

namespace PzTools.LocalizationSmoke;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(parameters =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new SmokeApp(args[0], args[1]);
        });
    }
}

internal sealed class SmokeApp(string stringsPath, string resultPath) : Application
{
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            // Load the real MRT resource pipeline, but never start AppHost or touch a user save.
            var count = 0;
            foreach (var language in LanguageCatalog.All.Concat(LanguageCatalog.All.Reverse()))
            {
                Localizer.SetLanguage(language.Id);
                if (Localizer.Culture.Name != language.Tag || CultureInfo.CurrentUICulture.Name != language.Tag)
                    throw new InvalidOperationException("Culture mismatch: " + language.Tag);
                var resource = XDocument.Load(Path.Combine(stringsPath, language.Tag, "Resources.resw"));
                foreach (var item in resource.Root!.Elements("data"))
                {
                    var key = item.Attribute("name")!.Value;
                    var expected = item.Element("value")!.Value;
                    var actual = Localizer.Get(key);
                    if (actual != expected)
                        throw new InvalidOperationException($"{language.Tag}/{key}: expected '{expected}', got '{actual}'.");
                    var arguments = Enumerable.Repeat<object>(42, CompositeFormat.Parse(expected).MinimumArgumentCount).ToArray();
                    if (Localizer.Format(key, arguments) != string.Format(Localizer.Culture, expected, arguments))
                        throw new InvalidOperationException("Formatting mismatch: " + key);
                    count++;
                }
            }
            File.WriteAllText(resultPath, $"PASS: {LanguageCatalog.All.Count} locales, {count} resource/format checks, forward and reverse switching; no AppHost/game/save access.");
        }
        catch (Exception error)
        {
            File.WriteAllText(resultPath, "FAIL: " + error);
            Environment.ExitCode = 1;
        }
        finally { Exit(); }
    }
}
