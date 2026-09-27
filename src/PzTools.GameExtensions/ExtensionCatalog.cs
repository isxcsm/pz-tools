using System.Text;

namespace PzTools.GameExtensions;

/// <summary>One deployment catalogue shared by UI and JVM. Updating an adapter need not rebuild the UI.</summary>
public static class ExtensionCatalog
{
    public static IReadOnlyList<ExtensionDefinition> BuiltIn { get; } = ReadEmbedded();
    private static IReadOnlyList<ExtensionDefinition> ReadEmbedded()
    {
        using var input = typeof(ExtensionCatalog).Assembly.GetManifestResourceStream("PzTools.GameExtensions.catalog.tsv")
            ?? throw new InvalidDataException("Missing extension catalogue.");
        using var reader = new StreamReader(input, Encoding.UTF8);
        return Parse(reader.ReadToEnd());
    }
    public static IReadOnlyList<ExtensionDefinition> ReadFile(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (stream.Length > 65536) throw new InvalidDataException("Oversized extension catalogue.");
        using var reader = new StreamReader(stream, new UTF8Encoding(false, true));
        return Parse(reader.ReadToEnd());
    }
    public static IReadOnlyList<ExtensionDefinition> Parse(string text)
    {
        if (text.Length > 65536) throw new InvalidDataException("Oversized extension catalogue.");
        var result = new List<ExtensionDefinition>();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var line in text.Split('\n'))
        {
            var row = line.TrimEnd('\r');
            if (string.IsNullOrWhiteSpace(row) || row.StartsWith('#')) continue;
            var p = row.Split('\t');
            if (p.Length is not (10 or 11) || !Enum.TryParse<VersionSupportScope>(p[5], out var scope) || !Enum.IsDefined(scope))
                throw new InvalidDataException("Invalid extension catalogue row.");
            var capability = p.Length == 10 ? ExtensionCapabilities.SavePreparation : p[10];
            var capabilities = Array.AsReadOnly(new[] { capability });
            var activationKind = ExtensionCapabilities.Classify(capabilities);
            if (activationKind == ExtensionActivationKind.Unsupported)
                throw new InvalidDataException("Unsupported extension capability.");
            if (p[0] == ExtensionIds.VehicleDrivetrain && capability != ExtensionCapabilities.VehicleDrivetrain)
                throw new InvalidDataException("The vehicle extension requires an explicit vehicle capability.");
            try { ExtensionIds.Validate(p[0]); } catch (ArgumentException failure) { throw new InvalidDataException("Invalid extension catalogue identifier.", failure); }
            if (!ids.Add(p[0]) || result.Count >= 64 || p.Any(part => part.Length > 200)
                || !Version.TryParse(p[1], out _) || !p[8].StartsWith("Extension.", StringComparison.Ordinal)
                || !p[9].StartsWith("Extension.", StringComparison.Ordinal))
                throw new InvalidDataException("Invalid extension catalogue identity.");
            var support = new GameVersionSupport(scope, p[6] == "-" ? null : p[6], p[7] == "-" ? null : p[7]).Validate();
            result.Add(new(p[0], p[1], p[8], p[9], activationKind == ExtensionActivationKind.PerSave ? "compatibility-on-request" : "runtime-pending",
                capabilities, support));
        }
        return result.AsReadOnly();
    }
}
