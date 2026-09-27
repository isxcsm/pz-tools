namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests
{
    private static void InstallTestSaveProvider(string bridge)
    {
        var extensions = Path.Combine(bridge, "extensions");
        File.Copy(Environment.GetEnvironmentVariable("PZTOOLS_EXTENSION_FIXTURE_JAR")!,
            Path.Combine(extensions, "pztools-test-save.jar"), true);
        File.AppendAllText(Path.Combine(extensions, "catalog.tsv"), "\n" + string.Join('\t',
            "pztools.test-save", "0.1.0", "pztools.extensions.fixture",
            "pztools.extensions.fixture.TestSaveProvider", "pztools-test-save.jar", "All", "-", "-",
            "Extension.Test.Title", "Extension.Test.Description", "save.prepare.v1") + "\n");
    }
}
