using System.Collections.ObjectModel;

namespace PzTools.Process.Contracts;

public enum SupportedLanguage
{
    Korean, English, ChineseSimplified, ChineseTraditional, Japanese, Russian,
    PortugueseBrazil, Spanish, French, German, Polish, Turkish, Ukrainian,
    Italian, Thai, Indonesian, Czech, SpanishLatinAmerica,
}

public sealed record LanguageDefinition(SupportedLanguage Id, string Tag, string NativeName,
    string BackupName, string ManualBackupName, string AutomaticBackupName,
    string SaveCountdown, string SaveCompleted, string SaveFailed, string SaveInProgress);

/// <summary>Shared locale identifiers, persisted-name compatibility and worker messages.</summary>
public static class LanguageCatalog
{
    public static IReadOnlyList<LanguageDefinition> All { get; } = Load();
    private static readonly IReadOnlyDictionary<SupportedLanguage, LanguageDefinition> ById =
        All.ToDictionary(language => language.Id);
    private static readonly Dictionary<string, SupportedLanguage> ByName = CreateNames();

    public static LanguageDefinition Get(SupportedLanguage language) =>
        ById.TryGetValue(language, out var value) ? value
            : throw new ArgumentOutOfRangeException(nameof(language));

    public static bool TryParse(string? value, out SupportedLanguage language)
    {
        language = default;
        return value is not null && ByName.TryGetValue(value, out language);
    }

    public static SupportedLanguage Parse(string value) => TryParse(value, out var language)
        ? language : throw new ArgumentException($"Unsupported language '{value}'.", nameof(value));

    private static Dictionary<string, SupportedLanguage> CreateNames()
    {
        var names = new Dictionary<string, SupportedLanguage>(StringComparer.OrdinalIgnoreCase);
        foreach (var language in All)
        {
            names.Add(language.Tag, language.Id);
            names.Add(language.Id.ToString(), language.Id); // Existing Korean/English settings and CLI.
        }
        names.Add("ko", SupportedLanguage.Korean);
        names.Add("en", SupportedLanguage.English);
        return names;
    }

    private static ReadOnlyCollection<LanguageDefinition> Load()
    {
        using var stream = typeof(LanguageCatalog).Assembly.GetManifestResourceStream("PzTools.languages.tsv")
            ?? throw new InvalidOperationException("Language catalog is missing.");
        using var reader = new StreamReader(stream);
        var languages = new List<LanguageDefinition>();
        while (reader.ReadLine() is { } line)
        {
            var fields = line.Split('\t');
            if (fields.Length != 10) throw new InvalidDataException("Invalid language catalog entry.");
            languages.Add(new(Enum.Parse<SupportedLanguage>(fields[0]), fields[1], fields[2],
                fields[3], fields[4], fields[5], fields[6], fields[7], fields[8], fields[9]));
        }
        return languages.AsReadOnly();
    }
}
