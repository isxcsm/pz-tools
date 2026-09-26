package pztools.extensions.runtime;

import pztools.extensions.api.*;
import java.nio.file.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.jar.*;
import javax.tools.ToolProvider;

/** Real archived provider generations and callback races. No game classes or attach operation. */
public final class ContinuousRuntimeTest {
    public static volatile CountDownLatch entered, release;
    public static final AtomicInteger activations = new AtomicInteger(), closures = new AtomicInteger();
    public static volatile boolean ready = true, hold, fail, failClose, failHealth;
    public static volatile int preflightFailure;
    public static volatile boolean initializeFailure;
    public static volatile String appliedValue;
    public static void main(String[] args) throws Exception { run(); }
    public static void run() throws Exception {
        activations.set(0); closures.set(0);
        Path base = Files.createDirectories(Path.of("artifacts/vehicle-shared-tests").toAbsolutePath());
        Path root = Files.createTempDirectory(base, "pztools-continuous-");
        try {
            Files.writeString(root.resolve("catalog.tsv"), "fixture.vehicle\t1.0.0\tpztools.extensions.fixture\tpztools.extensions.fixture.Provider\tfixture.jar\tAll\t-\t-\ttitle\tdescription\tvehicle.drivetrain.v1\n");
            byte[] first = archive(root);
            Files.write(root.resolve("fixture.jar"), first);
            ClassLoader loader = ContinuousRuntimeTest.class.getClassLoader();
            Object world = new Object(); String worldId = RuntimeIdentity.worldId(world);
            var context = new ContinuousProvider.Context(RuntimeIdentity.processId(), worldId, world,
                Thread.currentThread(), loader, new AtomicBoolean(true));
            var runtime = new ContinuousRuntime(root);
            check(runtime.apply(request(worldId, -1, 0, "one"), null, loader, "42.20").state().equals("Pending"), "Activation must wait for game boundary");
            check(VehicleHooks.tryControl(null, 1, 0) == 0, "Pending activation affected physics");
            runtime.tick(context);
            var active = runtime.status();
            check(active.state().equals("Active") && active.appliedRevision() == 0 && activations.get() == 1, "Activation did not commit");
            check(VehicleHooks.tryControl(null, 1, 0) == 5, "Active provider not selected");
            check(runtime.apply(request(worldId, -1, 1, "two"), null, loader, "42.20").reason().equals("revision-conflict"), "Stale configuration admitted");
            check(runtime.apply(request(worldId, 0, 1, "bad"), null, loader, "42.20").reason().startsWith("update-rejected"), "Bad configuration accepted");
            check(runtime.status().state().equals("Active") && activations.get() == 1, "Rejected update retired healthy generation");
            ready = false;
            runtime.apply(request(worldId, 0, 1, "two"), null, loader, "42.20"); runtime.tick(context);
            check(runtime.status().state().equals("Pending") && runtime.status().appliedRevision() == 0, "Unsafe update applied");
            ready = true; runtime.tick(context);
            check(runtime.status().appliedRevision() == 1 && runtime.status().generation().equals(active.generation()), "Configuration needlessly reloaded generation");
            Files.write(root.resolve("fixture.jar"), new byte[] { 1, 2, 3 });
            runtime.apply(request(worldId, 1, 2, "three"), null, loader, "42.20");
            check(runtime.status().state().equals("Active") && closures.get() == 0, "Invalid archive retired active provider");
            Files.write(root.resolve("fixture.jar"), first);
            rejectedPreflightPreservesActive(runtime,root,first,worldId,loader);
            int beforeHeldClose=closures.get();
            heldRetirement(runtime);
            check(runtime.status().state().equals("Disabled") && closures.get() == beforeHeldClose+1, "Retirement did not finish");
            runtime.apply(request(worldId, -1, 2, "three"), null, loader, "42.20"); runtime.tick(context);
            fail = true;
            check(VehicleHooks.tryControl(null, 1, 0) == 0, "Callback exception escaped fallback");
            check(runtime.status().state().equals("FaultedPassThrough"), "Callback fault not reported");
            fail = false; check(VehicleHooks.tryControl(null, 1, 0) == 0, "Fault automatically retried");
            runtime.deactivate("reset");
            runtime.apply(request(worldId, -1, 3, "four"), null, loader, "42.20"); runtime.tick(context);
            failHealth = true;
            check(runtime.status().state().equals("FaultedPassThrough") && VehicleHooks.tryControl(null, 1, 0) == 0,
                "Provider-side retransformation failure remained Active without a callback");
            failHealth = false; runtime.deactivate("reset-health");
            runtime.apply(request(worldId, -1, 3, "four"), null, loader, "42.20"); runtime.tick(context);
            context.worldValid().set(false); runtime.tick(context);
            check(VehicleHooks.tryControl(null, 1, 0) == 0 && runtime.status().state().equals("Disabled"), "World invalidation left effect active");
            runtime.deactivate("world-ended"); runtime.close();
            check(runtime.apply(request(worldId, -1, 4, "five"), null, loader, "42.20").state().equals("Disabled"), "Closed host admitted activation");
            repeatedReplacement(root, first, world, worldId, loader);
            rejectedInstallAfterPreflight(root,first,world,worldId,loader);
            pendingLatestAndOff(root,world,worldId,loader);
            failClose = true;
            var broken = new ContinuousRuntime(root);
            context.worldValid().set(true);
            broken.apply(request(worldId, -1, 0, "one"), null, loader, "42.20"); broken.tick(context);
            check(broken.deactivate("test").state().equals("RestartRequired"), "Failed close was ignored");
            check(broken.apply(request(worldId, 0, 1, "two"), null, loader, "42.20").state().equals("RestartRequired"), "Poisoned host admitted replacement");
            failClose = false;
            System.out.println("PASS: continuous activation/config CAS, safe boundary, corrupt archive, generation drain, world/fault fallback and closed host");
        } finally {
            hold = false; fail = false; failClose = false; failHealth = false; ready = true; preflightFailure=0; initializeFailure=false;
            if (release != null) release.countDown();
            try (var paths = Files.walk(root)) { for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.delete(path); }
        }
    }
    private static ContinuousModules.Apply request(String world, long expected, long revision, String value) {
        return new ContinuousModules.Apply(RuntimeIdentity.processId(), world, expected, revision, "fixture.vehicle", false, Map.of("value", value));
    }
    private static void pendingLatestAndOff(Path root,Object world,String worldId,ClassLoader loader) throws Exception {
        var runtime=new ContinuousRuntime(root);
        var context=new ContinuousProvider.Context(RuntimeIdentity.processId(),worldId,world,Thread.currentThread(),loader,new AtomicBoolean(true));
        try {
            ready=true;
            runtime.apply(request(worldId,-1,10,"baseline"),null,loader,"42.20"); runtime.tick(context);
            String generation=runtime.status().generation();
            check(appliedValue.equals("baseline"),"Initial fixture configuration was not applied");
            ready=false;
            runtime.apply(request(worldId,10,11,"superseded"),null,loader,"42.20"); runtime.tick(context);
            runtime.apply(request(worldId,10,12,"latest"),null,loader,"42.20"); runtime.tick(context);
            check(runtime.status().state().equals("Pending") && runtime.status().appliedRevision()==10
                && appliedValue.equals("baseline") && runtime.status().generation().equals(generation),
                "Pending updates changed the acknowledged configuration or retired its generation");
            ready=true; runtime.tick(context);
            check(runtime.status().state().equals("Active") && runtime.status().appliedRevision()==12
                && appliedValue.equals("latest") && runtime.status().generation().equals(generation),
                "Safe-boundary resume did not apply only the latest pending revision");
            ready=false;
            runtime.apply(request(worldId,12,13,"cancelled"),null,loader,"42.20"); runtime.tick(context);
            check(runtime.deactivate("off-before-safe-boundary").state().equals("Disabled")
                && VehicleHooks.tryControl(null,1,0)==0,"OFF waited for an unsafe pending update to become ready");
            ready=true; runtime.tick(context);
            check(runtime.status().state().equals("Disabled") && appliedValue.equals("latest")
                && VehicleHooks.tryControl(null,1,0)==0,"A cancelled pending revision was resurrected on resume");
        } finally { ready=true; runtime.close(); }
    }
    private static void rejectedPreflightPreservesActive(ContinuousRuntime runtime,Path root,byte[] original,String worldId,ClassLoader loader) throws Exception {
        var active=runtime.status(); int initialActivations=activations.get();
        Files.write(root.resolve("fixture.jar"),variant(original,42));
        for(int mode:new int[]{1,2}) {
            preflightFailure=mode;
            var rejected=runtime.apply(request(worldId,active.appliedRevision(),2,"candidate"),null,loader,"42.20");
            check(rejected.state().equals("Active") && rejected.reason().startsWith("update-rejected"),"Candidate preflight failure changed activation state");
            var after=runtime.status();
            check(active.generation().equals(after.generation()) && active.moduleSha256().equals(after.moduleSha256())
                && after.appliedRevision()==active.appliedRevision() && activations.get()==initialActivations
                && VehicleHooks.tryControl(null,1,0)==5,"Candidate handle/live-code rejection retired or changed healthy generation");
        }
        preflightFailure=0; Files.write(root.resolve("fixture.jar"),original);
    }
    private static byte[] variant(byte[] original,int version) throws Exception {
        var bytes = new ByteArrayOutputStream();
        try (var input = new JarInputStream(new ByteArrayInputStream(original));
             var output = new JarOutputStream(bytes, input.getManifest())) {
            for (JarEntry entry; (entry = input.getNextJarEntry()) != null;) {
                output.putNextEntry(new JarEntry(entry.getName())); input.transferTo(output); output.closeEntry();
            }
            output.putNextEntry(new JarEntry("META-INF/fixture-generation")); output.write(version); output.closeEntry();
        }
        return bytes.toByteArray();
    }
    private static void rejectedInstallAfterPreflight(Path root,byte[] original,Object world,String worldId,ClassLoader loader) throws Exception {
        var runtime=new ContinuousRuntime(root);
        var context=new ContinuousProvider.Context(RuntimeIdentity.processId(),worldId,world,Thread.currentThread(),loader,new AtomicBoolean(true));
        runtime.apply(request(worldId,-1,0,"old"),null,loader,"42.20"); runtime.tick(context);
        Files.write(root.resolve("fixture.jar"),variant(original,43)); initializeFailure=true;
        try {
            var status=runtime.apply(request(worldId,0,1,"candidate"),null,loader,"42.20");
            check(status.state().equals("Unsupported") && status.generation()==null && VehicleHooks.tryControl(null,1,0)==0,
                "A conflict discovered during actual install did not safely return to original control");
        } finally { initializeFailure=false; runtime.close(); Files.write(root.resolve("fixture.jar"),original); }
    }
    private static void repeatedReplacement(Path root, byte[] original, Object world, String worldId, ClassLoader loader) throws Exception {
        var runtime = new ContinuousRuntime(root);
        var context = new ContinuousProvider.Context(RuntimeIdentity.processId(), worldId, world,
            Thread.currentThread(), loader, new AtomicBoolean(true));
        var generations = new HashSet<String>();
        int startedClosures = closures.get();
        for (int i = 0; i < 3; i++) {
            Files.write(root.resolve("fixture.jar"), variant(original,i));
            check(runtime.apply(request(worldId, i - 1, i, "replacement"), null, loader, "42.20").state().equals("Pending"), "Replacement not staged");
            check(VehicleHooks.tryControl(null, 1, 0) == 0, "Retired generation survived replacement before activation");
            runtime.tick(context);
            check(runtime.status().state().equals("Active") && generations.add(runtime.status().generation()), "Replacement reused a retired generation");
        }
        check(closures.get() == startedClosures + 2, "Replacement skipped a generation close");
        runtime.deactivate("off-without-another-tick");
        runtime.tick(context); // An already captured late game callback may not reactivate the retired generation.
        check(VehicleHooks.tryControl(null, 1, 0) == 0 && runtime.status().state().equals("Disabled"), "OFF required a later game tick");
        ready = false;
        runtime.apply(request(worldId, -1, 4, "pending"), null, loader, "42.20"); runtime.tick(context);
        runtime.deactivate("off-while-not-ready");
        ready = true; runtime.tick(context);
        check(VehicleHooks.tryControl(null, 1, 0) == 0, "A pending activation survived OFF");
        runtime.close(); Files.write(root.resolve("fixture.jar"), original);
    }
    private static void heldRetirement(ContinuousRuntime runtime) throws Exception {
        hold = true; entered = new CountDownLatch(1); release = new CountDownLatch(1);
        var result = new AtomicInteger(); var retired = new AtomicReference<ContinuousModules.Status>();
        Thread callback = new Thread(() -> result.set(VehicleHooks.tryControl(null, 1, 0)));
        callback.start(); check(entered.await(2, TimeUnit.SECONDS), "Held callback did not enter");
        runtime.revoke("test-revoke");
        check(VehicleHooks.tryControl(null, 1, 0) == 0, "Revoke did not immediately close admission");
        Thread closer = new Thread(() -> retired.set(runtime.deactivate("test"))); closer.start();
        check(retired.get() == null, "Close completed while callback owned generation");
        release.countDown(); callback.join(2000); closer.join(2000); hold = false;
        check(!callback.isAlive() && !closer.isAlive() && result.get() == 5, "An accepted callback was interrupted or crossed generations");
        check(retired.get() != null && retired.get().state().equals("Disabled"), "Drained retirement failed");
    }
    private static byte[] archive(Path root) throws Exception {
        Path source = root.resolve("Provider.java"), classes = Files.createDirectory(root.resolve("classes"));
        Files.writeString(source, """
            package pztools.extensions.fixture;
            import pztools.extensions.api.*; import pztools.extensions.runtime.ContinuousRuntimeTest;
            import java.util.*; import java.lang.instrument.Instrumentation;
            public final class Provider implements ContinuousProvider {
              private VehicleHooks.Retirement retirement;
              public String id(){return "fixture.vehicle";}
              public Support preflight(Instrumentation i,ClassLoader l,PreflightSource source)throws Exception{
                if(ContinuousRuntimeTest.preflightFailure==1)return new Support(false,"controller-contract-changed");
                if(ContinuousRuntimeTest.preflightFailure==2)throw new NoSuchFieldException("fixture-handle-contract");
                return new Support(true,null);}
              public Support initialize(Instrumentation i,ClassLoader l){return new Support(!ContinuousRuntimeTest.initializeFailure,"fixture-install-conflict");}
              public void validateConfig(Map<String,String> c){if(c.get("value").equals("bad"))throw new IllegalArgumentException("bad");}
              public boolean readyToActivate(Context c,Map<String,String> config){c.requireGameThread();return ContinuousRuntimeTest.ready;}
              public void activate(Context c,Map<String,String> config){c.requireGameThread();ContinuousRuntimeTest.activations.incrementAndGet();ContinuousRuntimeTest.appliedValue=config.get("value");
                VehicleHooks.register(this,(controller,mode,speed)->{
                  if(ContinuousRuntimeTest.fail)throw new IllegalArgumentException("fixture-before-commit");
                  if(ContinuousRuntimeTest.hold){ContinuousRuntimeTest.entered.countDown();if(!ContinuousRuntimeTest.release.await(2,java.util.concurrent.TimeUnit.SECONDS))throw new IllegalStateException("held");}
                  return VehicleHooks.APPLIED|VehicleHooks.OWN_OFFROAD;
                });}
              public void updateConfig(Map<String,String> c){ContinuousRuntimeTest.appliedValue=c.get("value");}
              public String failureReason(){return ContinuousRuntimeTest.failHealth?"fixture-transformation-failed":null;}
              public synchronized void deactivate(){if(retirement==null)retirement=VehicleHooks.unregister(this);}
              public void close()throws Exception{deactivate();if(retirement!=null)retirement.await(5000);ContinuousRuntimeTest.closures.incrementAndGet();if(ContinuousRuntimeTest.failClose)throw new java.io.IOException("fixture-close");}
            }
            """);
        int code = ToolProvider.getSystemJavaCompiler().run(null, null, null, "--release", "25", "-cp", System.getProperty("java.class.path"), "-d", classes.toString(), source.toString());
        check(code == 0, "Fixture compilation failed");
        var manifest = new Manifest(); manifest.getMainAttributes().putValue("Manifest-Version", "1.0");
        manifest.getMainAttributes().putValue("PzTools-Extension-Api", Integer.toString(ExtensionApi.HOST_ABI));
        var bytes = new ByteArrayOutputStream();
        try (var jar = new JarOutputStream(bytes, manifest); var paths = Files.walk(classes)) {
            for (Path path : paths.filter(Files::isRegularFile).toList()) {
                jar.putNextEntry(new JarEntry(classes.relativize(path).toString().replace('\\', '/'))); jar.write(Files.readAllBytes(path)); jar.closeEntry();
            }
        }
        return bytes.toByteArray();
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
