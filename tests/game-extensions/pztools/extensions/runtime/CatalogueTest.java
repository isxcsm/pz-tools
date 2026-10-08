package pztools.extensions.runtime;

import java.io.IOException;
import java.nio.file.*;
import java.util.Comparator;

/** The one catalogue parser the host uses when it loads and on every request. */
public final class CatalogueTest {
    private static final String ROW = "pztools.sample\t1.2.0\tpztools.extensions.sample\tpztools.extensions.sample.Provider\tsample.jar\tMajor\t42\t-\tExtension.Sample.Title\tExtension.Sample.Description";

    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("pztools-catalogue-");
        try {
            var continuous = read(root, "# comment\n\n" + ROW + "\tcontinuous.v1\n");
            var sample = continuous.get("pztools.sample");
            check(sample.continuous() && sample.capability().equals("continuous.v1") && sample.version().equals("1.2.0")
                && sample.namespace().equals("pztools.extensions.sample") && sample.entry().equals("pztools.extensions.sample.Provider")
                && sample.jar().equals("sample.jar") && sample.support().matches("42.20") && !sample.support().matches("41.78"), "row fields");
            check(read(root, ROW + "\tvehicle.drivetrain.v1\n").get("pztools.sample").continuous(), "the earlier capability name is still continuous");
            var save = read(root, ROW + "\n").get("pztools.sample");
            check(save.capability().equals(Catalogue.SAVE) && !save.continuous(), "a 10-column row is a save provider");
            check(read(root, ROW + "\tcontinuous.v1\r\n" + ROW.replace("pztools.sample", "pztools.other") + "\tcontinuous.v1\r\n").size() == 2, "CRLF rows");

            rejected(root, ROW + "\tteleport.v1\n", "an unknown capability rejects the whole catalogue");
            rejected(root, ROW + "\tcontinuous.v1\n" + ROW + "\tcontinuous.v1\n", "a duplicate id");
            rejected(root, ROW.replace("pztools.sample\t", "Sample\t") + "\tcontinuous.v1\n", "an invalid id");
            rejected(root, ROW.replace("pztools.sample\t", "pztools." + "a".repeat(80) + "\t") + "\tcontinuous.v1\n", "an id over 80 characters");
            rejected(root, ROW.replace("\t1.2.0\t", "\tnew\t") + "\tcontinuous.v1\n", "an invalid module version");
            rejected(root, ROW.replace("\tpztools.extensions.sample\t", "\tpztools.other\t") + "\tcontinuous.v1\n", "a namespace outside pztools.extensions");
            rejected(root, ROW.replace("\tpztools.extensions.sample.Provider\t", "\tpztools.extensions.elsewhere.Provider\t") + "\tcontinuous.v1\n", "an entry class outside the namespace");
            rejected(root, ROW.replace("\tsample.jar\t", "\t../sample.jar\t") + "\tcontinuous.v1\n", "a jar outside the folder");
            rejected(root, ROW.replace("\tMajor\t42\t-\t", "\tMajor\t-\t-\t") + "\tcontinuous.v1\n", "a range without a minimum");
            rejected(root, ROW + "\tcontinuous.v1\textra\n", "a row with 12 columns");
            check(read(root, rowsOf(64)).size() == 64, "64 rows");
            rejected(root, rowsOf(65), "more than 64 rows");
            rejected(root, "#" + "x".repeat(65536) + "\n", "an oversized file");
            Files.delete(root.resolve("catalog.tsv"));
            try { Catalogue.read(root); throw new AssertionError("a missing catalogue was read"); } catch (IOException expected) { }
            check(Catalogue.validId("pztools.vehicle-drivetrain") && !Catalogue.validId("vehicle") && !Catalogue.validId(null), "module id rule");
            System.out.println("PASS catalogue: fields, capability names, save rows and every rejection rule");
        } finally {
            try (var paths = Files.walk(root)) { for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.delete(path); }
        }
    }
    private static String rowsOf(int count) {
        var rows = new StringBuilder();
        for (int i = 0; i < count; i++) rows.append(ROW.replace("pztools.sample", "pztools.sample" + i)).append("\tcontinuous.v1\n");
        return rows.toString();
    }
    private static java.util.Map<String, Catalogue.Definition> read(Path root, String text) throws IOException {
        Files.writeString(root.resolve("catalog.tsv"), text);
        return Catalogue.read(root);
    }
    private static void rejected(Path root, String text, String what) {
        try { read(root, text); }
        catch (IOException expected) { return; }
        throw new AssertionError(what + " was accepted");
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
