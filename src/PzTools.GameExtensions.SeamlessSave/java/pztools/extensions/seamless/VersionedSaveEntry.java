package pztools.extensions.seamless;

/** Owned entry point for this save module. Never installed in place of a game's public save method. */
public interface VersionedSaveEntry {
    void saveForBackup() throws Throwable;
}
