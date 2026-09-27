using PzTools.Process.Contracts;
using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Engine;

public sealed record BackupExecutionOptions(
    long? RunIndex = null,
    long? Revision = null,
    SupportedLanguage NameLanguage = SupportedLanguage.Korean)
{
    public void Validate()
    {
        if (RunIndex is <= 0) throw new ArgumentOutOfRangeException(nameof(RunIndex));
        if (Revision is <= 0) throw new ArgumentOutOfRangeException(nameof(Revision));
        if (!Enum.IsDefined(NameLanguage)) throw new ArgumentOutOfRangeException(nameof(NameLanguage));
    }
}
