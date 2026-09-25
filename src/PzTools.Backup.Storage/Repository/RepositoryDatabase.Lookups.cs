namespace PzTools.Backup.Storage.Repository;

public sealed partial class RepositoryDatabase
{
    // Small USN deltas should drive the lookup, not scan every live entry. For
    // large requests allow a current-only scan. Never scan historical versions.
    internal const int RequestDrivenLookupThreshold = 1024;
    internal const string PathsRequestFirstFrom =
        "requested_paths AS requested CROSS JOIN paths AS requested_path ON requested_path.path_key=requested.path_key "
        + "CROSS JOIN current_entry_catalog AS entry ON entry.path_id=requested_path.path_id";
    internal const string PathsScanFrom =
        "current_entry_catalog AS entry JOIN requested_paths AS requested ON requested.path_key=entry.path_key";

    internal const string TrackedPathsRequestFirstSql =
        """
        SELECT spelling.display_path, entry.entry_kind, entry.file_id, entry.parent_file_id
        FROM requested_file_references AS requested
        CROSS JOIN entry_versions AS entry INDEXED BY ix_entry_versions_current_file_reference
          ON substr(entry.file_id, 9, 16)=requested.value
        JOIN path_spellings AS spelling
          ON spelling.path_id=entry.path_id AND spelling.spelling_id=entry.spelling_id
        WHERE entry.source_id=$sourceId AND entry.valid_to_revision IS NULL
          AND entry.tombstone=0 AND entry.file_id IS NOT NULL;
        """;

    internal const string TrackedPathsScanSql =
        """
        SELECT spelling.display_path, entry.entry_kind, entry.file_id, entry.parent_file_id
        FROM entry_versions AS entry INDEXED BY ix_entry_versions_current_file_reference
        JOIN requested_file_references AS requested ON requested.value=substr(entry.file_id, 9, 16)
        JOIN path_spellings AS spelling
          ON spelling.path_id=entry.path_id AND spelling.spelling_id=entry.spelling_id
        WHERE entry.source_id=$sourceId AND entry.valid_to_revision IS NULL
          AND entry.tombstone=0 AND entry.file_id IS NOT NULL;
        """;
}
