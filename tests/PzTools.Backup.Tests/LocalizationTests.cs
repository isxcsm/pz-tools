using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using PzTools.App.Core;
using PzTools.Backup.Core.Configuration;
using PzTools.Process.Contracts;
using PzTools.Projections;
using PzTools.Scheduling;

namespace PzTools.Backup.Tests;

public sealed class LocalizationTests
{
    public static IEnumerable<object[]> Languages => LanguageCatalog.All.Select(language => new object[] { language.Id });

    [Fact]
    public void Catalog_HasEveryEnumAndUniqueSupportedCultures()
    {
        Assert.Equal(18, LanguageCatalog.All.Count);
        Assert.Equal(Enum.GetValues<SupportedLanguage>().Order(), LanguageCatalog.All.Select(x => x.Id).Order());
        Assert.Equal(18, LanguageCatalog.All.Select(x => x.Tag).Distinct(StringComparer.OrdinalIgnoreCase).Count());
        Assert.Equal(18, LanguageCatalog.All.Select(x => x.NativeName).Distinct().Count());
        foreach (var language in LanguageCatalog.All)
        {
            Assert.Equal(language.Tag, CultureInfo.GetCultureInfo(language.Tag).Name);
            Assert.Equal(language.Id, LanguageCatalog.Parse(language.Tag));
            Assert.Equal(language.Id, LanguageCatalog.Parse(language.Tag.ToLowerInvariant()));
            Assert.Equal(language.Id, LanguageCatalog.Parse(language.Id.ToString()));
            Assert.Equal(1, CompositeFormat.Parse(language.SaveCountdown).MinimumArgumentCount);
            Assert.DoesNotContain('\t', language.SaveCompleted);
            Assert.DoesNotContain('\n', language.SaveFailed);
        }
        Assert.Equal(SupportedLanguage.Korean, LanguageCatalog.Parse("ko"));
        Assert.Equal(SupportedLanguage.English, LanguageCatalog.Parse("en"));
        foreach (var invalid in new string?[] { null, "", "ar-SA", "999", "0", "en-US\tSAVE" })
            Assert.False(LanguageCatalog.TryParse(invalid, out _));
        Assert.Throws<ArgumentOutOfRangeException>(() => LanguageCatalog.Get((SupportedLanguage)999));
    }

    [Theory]
    [MemberData(nameof(Languages))]
    public void Resources_HaveEveryKeyAndPreserveFormatting(SupportedLanguage language)
    {
        var strings = Path.Combine(FindRepository(), "src", "PzTools.App", "Strings");
        var baseline = ReadResources(Path.Combine(strings, "en-US", "Resources.resw"));
        var definition = LanguageCatalog.Get(language);
        var localized = ReadResources(Path.Combine(strings, definition.Tag, "Resources.resw"));
        Assert.Equal(baseline.Keys.Order(), localized.Keys.Order());
        foreach (var (key, source) in baseline)
        {
            var value = localized[key];
            Assert.False(string.IsNullOrWhiteSpace(value), $"{definition.Tag}: {key}");
            Assert.DoesNotContain("\uFFFD", value);
            Assert.DoesNotContain("⟪", value);
            Assert.DoesNotContain("⟦", value);
            Assert.Equal(FormatTokens(source), FormatTokens(value));
            var format = CompositeFormat.Parse(value);
            var arguments = Enumerable.Repeat<object>(42, format.MinimumArgumentCount).ToArray();
            _ = string.Format(CultureInfo.GetCultureInfo(definition.Tag), format, arguments);
            Assert.Equal(source.Count(c => c == '\n'), value.Count(c => c == '\n'));
        }
        Assert.Equal(definition.ManualBackupName + " {0:N0}", localized["ManualBackupNameFormat"]);
        Assert.Equal(definition.AutomaticBackupName + " {0:N0}", localized["AutomaticBackupNameFormat"]);
    }

    [Theory]
    [MemberData(nameof(Languages))]
    public async Task Language_RoundTripsThroughAppProjectionAndWorkerWithoutChangingOtherSettings(SupportedLanguage language)
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var settings = AppSettings.CreateDefault() with
        {
            Language = language, SavesRoot = temp.GetPath("saves"), BackupRoot = temp.GetPath("backups"),
            BackupIntervalMinutes = 0, RetainedRevisions = 37,
        };
        await service.SaveAndApplyAsync(settings, scheduler);
        var loaded = new AppSettingsService(service.RuntimeRoot).Load();
        Assert.Equal(settings, loaded);
        var tag = LanguageCatalog.Get(language).Tag;
        Assert.Contains($"language = \"{tag}\"", File.ReadAllText(service.SettingsPath));
        var views = new RevisionedViewStore();
        new SettingsProjector(views).Project(loaded);
        Assert.Equal(tag, views.ReadIfChanged<SettingsView>(ViewKey.Settings, 0).Snapshot!.Language);
        var options = BackupConfiguration.Load(settings.BackupRoot,
            overrides: new() { Sources = [new("test", settings.SavesRoot)] },
            appSettingsPath: service.SettingsPath, configurationRoot: service.ConfigurationRoot);
        Assert.Equal(language, options.NameLanguage);
        Assert.Equal(language, BackupConfiguration.Parse(BackupConfiguration.Serialize(options),
            settings.BackupRoot, temp.GetPath("roundtrip.toml")).NameLanguage);
    }

    [Theory]
    [InlineData("Korean", SupportedLanguage.Korean)]
    [InlineData("English", SupportedLanguage.English)]
    public void LegacyLanguageSettingsRemainReadableWithoutRewriting(string name, SupportedLanguage language)
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        Directory.CreateDirectory(service.RuntimeRoot);
        var original = $"[ui]\nlanguage = '{name}'\n";
        File.WriteAllText(service.SettingsPath, original);
        Assert.Equal(language, service.Load().Language);
        Assert.Equal(original, File.ReadAllText(service.SettingsPath));
    }

    private static string[] FormatTokens(string value) => Regex.Matches(value, @"\{\d+[^{}]*\}")
        .Select(match => match.Value).Order().ToArray();

    private static Dictionary<string, string> ReadResources(string path) => XDocument.Load(path).Root!
        .Elements("data").ToDictionary(data => data.Attribute("name")!.Value, data => data.Element("value")!.Value);

    private static string FindRepository()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "src", "PzTools.App", "PzTools.App.csproj")))
                return directory.FullName;
        throw new DirectoryNotFoundException("Cannot find the repository resources.");
    }
}
