using PzTools.Process.Contracts;
using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Engine;

public sealed record BackupExecutionOptions(
    long? RunIndex = null,
    long? Revision = null,
    // No language named: this PC's (LanguageCatalog.Local).
    SupportedLanguage? NameLanguage = null,
    string? GameVersion = null)
{
    public void Validate()
    {
        if (RunIndex is <= 0) throw new ArgumentOutOfRangeException(nameof(RunIndex));
        if (Revision is <= 0) throw new ArgumentOutOfRangeException(nameof(Revision));
        if (NameLanguage is { } language && !Enum.IsDefined(language)) throw new ArgumentOutOfRangeException(nameof(NameLanguage));
        if (GameVersion is { Length: > 80 } || GameVersion?.Any(char.IsControl) == true)
            throw new ArgumentOutOfRangeException(nameof(GameVersion));
    }
}
