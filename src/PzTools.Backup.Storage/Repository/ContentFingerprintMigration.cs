namespace PzTools.Backup.Storage.Repository;

internal static class ContentFingerprintMigration
{
    // Run inside the migration runner's transaction. Dropping only the two leaf
    // columns keeps stored_objects' identity, indexes and incoming FKs intact.
    // Drop content_hash first because its CHECK refers to content_hash_algorithm.
    // The primary key makes the refill linear-logarithmic, not a scan per object.
    public const string Sql =
        """
        CREATE TEMP TABLE migration_content_fingerprints (
            object_id TEXT NOT NULL PRIMARY KEY,
            fingerprint BLOB NOT NULL CHECK(length(fingerprint)=16)
        ) WITHOUT ROWID;
        INSERT INTO migration_content_fingerprints(object_id,fingerprint)
            SELECT object_id,substr(content_hash,1,16) FROM stored_objects
            WHERE content_hash_algorithm='Sha256' AND content_hash IS NOT NULL;

        ALTER TABLE stored_objects DROP COLUMN content_hash;
        ALTER TABLE stored_objects DROP COLUMN content_hash_algorithm;
        ALTER TABLE stored_objects ADD COLUMN content_hash_algorithm TEXT NULL
            CHECK(content_hash_algorithm IS NULL OR content_hash_algorithm IN ('Sha256','Sha256_128'));
        ALTER TABLE stored_objects ADD COLUMN content_hash BLOB NULL
            CHECK((content_hash IS NULL AND content_hash_algorithm IS NULL)
                OR (content_hash IS NOT NULL AND content_hash_algorithm IS NOT NULL
                    AND ((content_hash_algorithm='Sha256_128' AND length(content_hash)=16)
                        OR (content_hash_algorithm='Sha256' AND length(content_hash)=32))));
        UPDATE stored_objects
            SET (content_hash_algorithm,content_hash)=(
                SELECT 'Sha256_128',fingerprint FROM migration_content_fingerprints
                WHERE object_id=stored_objects.object_id)
            WHERE object_id IN (SELECT object_id FROM migration_content_fingerprints);
        DROP TABLE migration_content_fingerprints;
        UPDATE repository_info SET schema_version=12 WHERE singleton=1;
        """;
}
