import pztools.extensions.api.*;
import pztools.extensions.runtime.ModuleHost;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.jar.*;
import javax.tools.ToolProvider;

/** Real module host + independently compiled JAR generations; no game, GC deadline or source-text assertions. */
public final class ModuleReloadTest {
    public static void run() throws Exception {
        pairedObservation();
        Path root = Files.createTempDirectory("pztools-reload-");
        try {
            Files.writeString(root.resolve("catalog.tsv"), "fixture.save\t1.0.0\tpztools.extensions.fixture\tpztools.extensions.fixture.Provider\tfixture.jar\tAll\t-\t-\ttitle\tdescription\n");
            byte[] one = archive(root, "one", false), two = archive(root, "two", false);
            Files.write(root.resolve("fixture.jar"), one);
            try (var host = new Host(root)) {
                var context = new SaveProvider.Context("request", "session", "world", root, Thread.currentThread(), ModuleReloadTest.class.getClassLoader());
                var old = host.value.resolve("fixture.save", null, context.gameClasses(), "42.20", false).provider();
                check(old != null && old == host.value.resolve("fixture.save", null, context.gameClasses(), "42.20", false).provider(), "Unchanged JAR was reloaded");
                var first = host.value.begin(old, context);
                waitFile(root.resolve("started"));
                Files.write(root.resolve("fixture.jar"), two);
                check(host.value.resolve("fixture.save", null, context.gameClasses(), "42.20", false).reason().equals("module-update-busy"), "Running save was retired");
                check(!Files.exists(root.resolve("closed-one")), "Old module closed during write");
                Files.writeString(root.resolve("release"), "go"); await(first);
                check(Files.readString(root.resolve("saved")).equals("one"), "Running job mixed generations");
                var next = host.value.resolve("fixture.save", null, context.gameClasses(), "42.20", false).provider();
                check(next != null && next != old && Files.exists(root.resolve("closed-one")), "Changed bytes did not retire old provider");
                try { host.value.begin(old, context); throw new AssertionError("Stale resolution admitted"); }
                catch (IllegalStateException expected) { }
                var second = host.value.begin(next, context); await(second);
                check(Files.readString(root.resolve("saved")).equals("two") && second.diagnostics().contains("moduleSha256="), "New code/identity not executed");
                Files.write(root.resolve("fixture.jar"), new byte[]{1,2,3});
                check(host.value.resolve("fixture.save", null, context.gameClasses(), "42.20", false).provider() == null, "Corrupt update accepted");
                check(!Files.exists(root.resolve("closed-two")), "Invalid archive retired working code before validation");
                Files.write(root.resolve("fixture.jar"), two);
                check(host.value.resolve("fixture.save", null, context.gameClasses(), "42.20", false).provider() == next, "Invalid archive destroyed the previous generation");
                // A folder move with the same bytes is not a reload or a JVM restart.
                Path moved = Files.createDirectory(root.resolve("new-install"));
                Files.copy(root.resolve("catalog.tsv"), moved.resolve("catalog.tsv")); Files.copy(root.resolve("fixture.jar"), moved.resolve("fixture.jar"));
                host.value.relocate(moved);
                check(host.value.resolve("fixture.save", null, context.gameClasses(), "42.20", false).provider() == next, "Relocation unnecessarily reloaded module");
            }
            check(Files.exists(root.resolve("closed-two")), "Host close did not retire provider");
            byte[] badClose = archive(root, "bad", true);
            Files.write(root.resolve("fixture.jar"), badClose);
            ModuleHost poisoned = new ModuleHost(root);
            var old = poisoned.resolve("fixture.save", null, ModuleReloadTest.class.getClassLoader(), "42.20", false);
            check(old.provider() != null, "Closing-failure fixture not admitted");
            Files.write(root.resolve("fixture.jar"), two);
            check(poisoned.resolve("fixture.save", null, ModuleReloadTest.class.getClassLoader(), "42.20", false).reason().equals("module-restart-required"), "Uncertain retirement admitted replacement");
            check(poisoned.resolve("fixture.save", null, ModuleReloadTest.class.getClassLoader(), "42.20", true).provider() == null, "Version force bypassed failed retirement");
            System.out.println("PASS: JAR hot reload, unchanged reuse, in-flight save ownership, invalid update, path move and retirement failure");
        } finally {
            try (var paths = Files.walk(root)) { for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.delete(path); }
        }
    }
    private record Host(ModuleHost value) implements AutoCloseable {
        Host(Path path) throws Exception { this(new ModuleHost(path)); }
        public void close() throws Exception { value.close(); }
    }
    private static byte[] archive(Path root, String generation, boolean failClose) throws Exception {
        Path source = Files.createDirectories(root.resolve("src-" + generation)).resolve("Provider.java");
        String code = """
            package pztools.extensions.fixture;
            import pztools.extensions.api.*; import java.nio.file.*;
            public final class Provider implements SaveProvider {
              private Path root;
              public String id() { return "fixture.save"; }
              public boolean supportsReload() { return true; }
              public Support inspect(Context c) { return new Support(true,null); }
              public PreparedSave capture(Context c,long maximumBytes) throws Exception {
                c.requireGameThread(); root=c.sourcePath(); Files.writeString(root.resolve("started"),"VERSION");
                return new PreparedSave() {
                  public long retainedBytes(){ return 0; }
                  public void commit() throws Exception {
                    long deadline=System.nanoTime()+10_000_000_000L;
                    while(!Files.exists(root.resolve("release"))) { if(System.nanoTime()>deadline)throw new java.io.IOException("Fixture deadline"); Thread.sleep(1); }
                    Files.writeString(root.resolve("saved"),"VERSION");
                  }
                  public void close() { }
                };
              }
              public void close() throws Exception {
                if(FAIL_CLOSE)throw new java.io.IOException("Retirement failed");
                if(root!=null)Files.writeString(root.resolve("closed-VERSION"),"closed");
              }
            }
            """.replace("VERSION", generation).replace("FAIL_CLOSE", Boolean.toString(failClose));
        Files.writeString(source, code); Path classes=Files.createDirectories(root.resolve("classes-"+generation));
        int result=ToolProvider.getSystemJavaCompiler().run(null,null,null,"--release","25","-cp",System.getProperty("java.class.path"),"-d",classes.toString(),source.toString());
        check(result==0,"Fixture compilation failed");
        var manifest=new Manifest();manifest.getMainAttributes().putValue("Manifest-Version","1.0");manifest.getMainAttributes().putValue("PzTools-Extension-Api","2");
        var bytes=new ByteArrayOutputStream();
        try(var jar=new JarOutputStream(bytes,manifest);var files=Files.walk(classes)) {
            for(Path path:files.filter(Files::isRegularFile).toList()) {
                jar.putNextEntry(new JarEntry(classes.relativize(path).toString().replace('\\','/')));jar.write(Files.readAllBytes(path));jar.closeEntry();
            }
        }
        return bytes.toByteArray();
    }
    private static void pairedObservation() throws Exception {
        var first=new AtomicInteger();var second=new AtomicInteger();String point="fixture.generation";
        GameHooks.Observer old=new GameHooks.Observer(){public void exit(Throwable e){first.incrementAndGet();}};
        GameHooks.Observer next=new GameHooks.Observer(){public void exit(Throwable e){second.incrementAndGet();}};
        GameHooks.register(point,old);GameHooks.enter(point);var retired=GameHooks.unregister(point,old);
        GameHooks.register(point,next);GameHooks.exit(point,null);retired.await(1000);
        check(first.get()==1&&second.get()==0,"Late exit crossed observer generations");
        GameHooks.enter(point);GameHooks.exit(point,null);GameHooks.unregister(point,next).await(1000);
        check(second.get()==1,"New generation did not receive its own callback");
    }
    private static void waitFile(Path path)throws Exception{long end=System.nanoTime()+10_000_000_000L;while(!Files.exists(path)){if(System.nanoTime()>end)throw new AssertionError("Fixture did not start");Thread.sleep(1);}}
    private static void await(SaveTask task)throws Exception{long end=System.nanoTime()+10_000_000_000L;while(task.completed()==null){if(System.nanoTime()>end)throw new AssertionError("Fixture did not finish");Thread.sleep(1);}check(task.completed().failure()==null,"Save failed: "+task.completed().failure());}
    private static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
}
